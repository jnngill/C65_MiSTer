// Commodore 65 system core (platform independent; wrapped by C65.sv on MiSTer
// and by sim/system/tb.cpp under Verilator).
//
// clk is 32x the 1 MHz phase clock (~31.5 MHz PAL, ~32.7 MHz NTSC).

module c65_core (
	input  logic        clk,
	input  logic        reset_in,
	input  logic        ntsc,
	input  logic        dma_f018b,
	input  logic  [1:0] turbo,            // CPU speed in FAST mode: 0 = 3.5 MHz, 1 = 8 MHz, 2 = 16 MHz

	// ROM image loader (128K, used while the machine is held in reset)
	input  logic [16:0] ld_addr,
	input  logic  [7:0] ld_data,
	input  logic        ld_wr,

	// MEGA65 programs may use $20000-$3FFFF as RAM.  A copy of the ROM image is
	// kept in external memory; after a reset that follows such writes the ROM
	// is copied back (rrom_*: request / acknowledge, like xram) while the
	// machine is held in reset.
	input  logic        rom_backup,       // the copy is valid
	output logic        rrom_req,
	output logic [16:0] rrom_addr,
	input  logic  [7:0] rrom_q,
	input  logic        rrom_ack,

	// program loader (OSD "Load Program", MiSTer ioctl style): prg_dl is high
	// for the whole download, prg_wr strobes byte prg_ofs of the .PRG file
	input  logic        prg_dl,
	input  logic        prg_wr,
	input  logic [15:0] prg_ofs,
	input  logic  [7:0] prg_byte,

	input  logic [10:0] ps2_key,
	input  logic  [1:0] kbd_layout,       // 0 US, 1 UK, 2 DE, 3 positional
	input  logic  [4:0] joy1, joy2,       // active high: fire, right, left, down, up
	input  logic [24:0] ps2_mouse,        // MiSTer hps_io mouse word
	input  logic  [1:0] mouse_port,       // 1351 mouse: 0 = none, 1 = control port 1, 2 = control port 2
	input  logic        m65_ext,          // allow the MEGA65 extensions; 0 = strict C65

	// IEC serial bus (1 = line released): the C65's outputs, and the drives' outputs
	output logic        iec_atn_o,
	output logic        iec_clk_o,
	output logic        iec_data_o,
	input  logic        iec_clk_i,
	input  logic        iec_data_i,

	// serial port (C65 UART)
	input  logic        uart_rxd,
	output logic        uart_txd,

	// video
	output logic        ce_pix,
	output logic  [3:0] r, g, b,
	output logic        hsync, vsync, hblank, vblank,
	output logic        field,            // interlaced modes: which field this frame carries

	// audio (signed)
	output logic [17:0] audio_l, audio_r,

	// floppy image (512 byte block interface, MiSTer hps_io style)
	input  logic  [1:0] img_mounted,      // bit 0 internal drive, bit 1 external 1565
	input  logic        img_readonly,
	input  logic [31:0] img_size,
	output logic [31:0] sd_lba,
	output logic  [1:0] sd_rd,
	output logic  [1:0] sd_wr,
	input  logic  [1:0] sd_ack,
	input  logic  [8:0] sd_buff_addr,
	input  logic  [7:0] sd_buff_dout,
	output logic  [7:0] sd_buff_din,
	input  logic        sd_buff_wr,

	// data file for the MEGA65 hypervisor DOS stand-in (m65_hyppo)
	input  logic        dfile_mounted,
	output logic [31:0] dfile_lba,
	output logic        dfile_rd,
	input  logic        dfile_ack,
	output logic        drive_led,

	// wall-clock time from the host (MiSTer hps_io RTC word), for the MEGA65 clock registers
	input  logic [64:0] rtc,

	// expansion RAM (external memory, request / acknowledge):
	//   $060000-$0FFFFF  banks 6-15, addressed as is (xram_addr[22] = 0)
	//   $400000-$7FFFFF  4 MB reached through DMA (xram_addr[22] = 1)
	//   MEGA65 attic RAM, 8 MB at $8000000 (xram_addr[23] = 1)
	input  logic        xram_present,
	input  logic        attic_present,
	output logic        xram_req,         // held until xram_ack
	output logic        xram_we,
	output logic [23:0] xram_addr,
	output logic  [7:0] xram_din,
	input  logic  [7:0] xram_dout,        // valid from xram_ack until the next request
	input  logic        xram_ack,

	// debug
	output logic [15:0] dbg_pc,
	output logic        dbg_sync,
	output logic  [7:0] dbg_op,           // opcode being fetched (valid with dbg_sync)
	output logic  [7:0] dbg_a, dbg_x, dbg_y, dbg_z, dbg_b, dbg_p,
	output logic [15:0] dbg_sp
);

// ------------------------------------------------------------------ ROM restore
logic        rom_dirty = 1'b0;     // $20000-$3FFFF was written (not cleared by reset)
logic        rom_restoring = 1'b0;
logic        rs_wr;
logic  [7:0] rs_data;
wire         rom_wr;               // a far / DMA write into $20000-$3FFFF
wire         reset = reset_in || rom_restoring;

always_ff @(posedge clk) begin
	rs_wr <= 1'b0;
	if (reset_in) begin
		rrom_req <= 1'b0; rrom_addr <= '0;
		if (rom_dirty && rom_backup) rom_restoring <= 1'b1;
	end
	else if (rom_restoring) begin
		if (!rrom_req && !rs_wr) rrom_req <= 1'b1;
		if (rrom_req && rrom_ack) begin rrom_req <= 1'b0; rs_wr <= 1'b1; rs_data <= rrom_q; end
		if (rs_wr) begin
			rrom_addr <= rrom_addr + 17'd1;
			if (&rrom_addr) begin rom_restoring <= 1'b0; rom_dirty <= 1'b0; end
		end
	end
	if (rom_wr) rom_dirty <= 1'b1;
	if (ld_wr)  rom_dirty <= 1'b0;
end

// ------------------------------------------------------------------ clocks
logic [4:0] ph;
always_ff @(posedge clk) ph <= reset ? 5'd0 : ph + 5'd1;

wire   ce640 = ph[0];          // 640-pixel clock enable for the video chip
// the video output enable: the 640-pixel rate, or every clk in 1280 pixel modes
wire   phi2_p = (ph == 5'd15);
wire   phi2_n = (ph == 5'd31);

// ------------------------------------------------------------------ CPU
logic [15:0] cpu_addr;
logic [19:0] cpu_paddr;
logic        cpu_mapped, cpu_we, cpu_ce;
logic        cpu_far;
logic [27:0] cpu_faddr;
logic        gs_mode;              // MEGA65 (VIC-IV) I/O was unlocked: 45GS02 extensions on
logic  [7:0] cpu_dout, bus_din;
logic        irq_n, nmi_n;
logic        hyp_busy, hyp_load, hyp_c;   // MEGA65 hypervisor trap stand-in
logic        dma_resume;                 // inline DMA done: CPU continues at dma_resume_pc
logic [15:0] dma_resume_pc;
logic  [7:0] hyp_a, hyp_x, hyp_y;

cpu4510 cpu (
	.clk(clk), .reset(reset), .ce(cpu_ce),
	.irq_n(irq_n), .nmi_n(nmi_n), .gs(gs_mode),
	.far_sel(cpu_far), .far_addr(cpu_faddr),
	.addr(cpu_addr), .paddr(cpu_paddr), .mapped(cpu_mapped),
	.dout(cpu_dout), .we(cpu_we), .din(bus_din),
	.sync(dbg_sync),
	.hyp_load(hyp_load), .hyp_a(hyp_a), .hyp_x(hyp_x), .hyp_y(hyp_y), .hyp_c(hyp_c),
	.pc_load(dma_resume), .pc_val(dma_resume_pc),
	.dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y), .dbg_z(dbg_z),
	.dbg_b(dbg_b), .dbg_p(dbg_p), .dbg_sp(dbg_sp)
);

// ------------------------------------------------------------------ DMA
logic        dma_busy, dma_io, dma_we, dma_ce, dma_setup;
logic [27:0] dma_addr;
logic  [7:0] dma_dout, dma_reg_dout;
logic        dma_reg_we;
logic [11:0] io_addr;
logic  [7:0] bus_dout;
logic        bus_we;

dma_f018 dma (
	.clk(clk), .reset(reset), .ce(dma_ce), .f018b(dma_f018b),
	.reg_addr(io_addr[2:0]), .reg_we(dma_reg_we), .reg_din(bus_dout), .reg_dout(dma_reg_dout),
	.cpu_pc(dbg_pc), .resume(dma_resume), .resume_pc(dma_resume_pc),
	.busy(dma_busy), .setup(dma_setup), .addr(dma_addr), .io(dma_io), .we(dma_we), .dout(dma_dout), .din(bus_din)
);

// ------------------------------------------------------------------ address decode
logic  [7:0] port_ddr, port_dat;
logic        capslock_n;
wire   [7:0] port_in  = {1'b1, capslock_n, 6'b111111};
wire   [7:0] port_val = (port_dat & port_ddr) | (port_in & ~port_ddr);
wire         loram = port_val[0], hiram = port_val[1], charen = port_val[2];

logic  [7:0] ctrl_a, ctrl_b;       // VIC-III $D030 / $D031
logic        vic3_mode;

assign bus_we   = dma_busy ? dma_we   : cpu_we;
assign bus_dout = dma_busy ? dma_dout : cpu_dout;

logic        sel_ram, sel_ram2, sel_wom, sel_rom, sel_io, sel_port, sel_xram, sel_rtc, sel_cram2, sel_sdbuf, sel_romw, sel_fdcbuf;
// a DMA address with the I/O flag only means I/O inside $D000-$DFFF; elsewhere it is plain memory
wire         dma_is_io = dma_io && (dma_addr[15:12] == 4'hD);
logic [23:0] xaddr;
logic [16:0] mem_addr;

always_comb begin
	logic [22:0] pa;
	logic [27:0] fa;       // flat 28-bit address: 45GS02 far pointer or DMA
	logic        flat;
	sel_ram = 1'b0; sel_ram2 = 1'b0; sel_cram2 = 1'b0; sel_sdbuf = 1'b0; sel_fdcbuf = 1'b0; sel_wom = 1'b0; sel_rom = 1'b0; sel_io = 1'b0; sel_port = 1'b0;
	sel_xram = 1'b0; sel_rtc = 1'b0; sel_romw = 1'b0;
	mem_addr = '0;
	io_addr  = dma_busy ? dma_addr[11:0] : cpu_far ? cpu_faddr[11:0] : cpu_addr[11:0];
	pa    = {3'd0, cpu_paddr};
	fa    = dma_busy ? dma_addr : cpu_faddr;
	flat  = dma_busy ? !dma_is_io : cpu_far;
	xaddr = flat ? {fa[27:23] == 5'b10000, fa[22:0]} : {1'b0, pa};

	if (flat) begin
		// flat 28-bit access: a 45GS02 far pointer, or the DMA controller
		mem_addr = fa[16:0];
		if (fa[27:17] == 11'd0)          sel_ram = 1'b1;             // $0000000 chip RAM
		else if (fa[27:17] == 11'd1) begin                          // $0020000 ROM (RAM to MEGA65 programs)
			sel_rom = !bus_we;
			sel_romw = bus_we && gs_mode;
		end
		else if (fa[27:17] == 11'd2)     sel_ram2 = 1'b1;            // $0040000 extra chip RAM
		else if (fa[27:22] == 6'd1)      sel_xram = xram_present;    // $0400000 expansion RAM
		else if (fa[27:23] == 5'b10000)  sel_xram = attic_present;   // $8000000 MEGA65 attic RAM
		else if (fa[27:20] == 8'd0)      sel_xram = xram_present;    // $0060000 banks 6-15
		else if (fa[27:12] == 16'hFF7E)  sel_wom = 1'b1;             // $FF7E000 character set
		else if (fa[27:11] == 17'h1FF00) begin sel_ram = 1'b1; mem_addr = {6'b111111, fa[10:0]}; end   // $FF80000 colour RAM
		else if (fa[27:15] == 13'h1FF0)  begin sel_cram2 = 1'b1; mem_addr = {2'd0, fa[14:0] - 15'h0800}; end   // $FF80800-$FF87FFF more colour RAM
		else if (fa[27:12] == 16'hFFD3)  sel_io = 1'b1;              // $FFD3000 I/O
		else if (fa[27:4] == 24'hFFD711) sel_rtc = 1'b1;             // $FFD7110 real-time clock
		else if (fa[27:9] == 19'h7FEB7)  begin sel_sdbuf = 1'b1; mem_addr = {8'd0, fa[8:0]}; end   // $FFD6E00 SD sector buffer
		else if (fa[27:9] == 19'h7FEB6)  begin sel_fdcbuf = 1'b1; mem_addr = {8'd0, fa[8:0]}; end  // $FFD6C00 F011 sector buffer
	end
	else if (!dma_busy && cpu_mapped) begin
		// 1MB address space reached through MAP
		mem_addr = pa[16:0];
		if (pa[19:17] == 3'd0)      sel_ram = 1'b1;
		else if (pa[19:17] == 3'd1) sel_rom = 1'b1;
		else if (pa[19:17] == 3'd2) sel_ram2 = 1'b1;
		else                        sel_xram = xram_present;      // banks 6-15
	end
	else if (dma_busy) sel_io = 1'b1;
	else begin
		// unmapped CPU access: C64 style banking plus the VIC-III ROM enables
		mem_addr = {1'b0, cpu_addr};
		sel_ram  = 1'b1;
		case (cpu_addr[15:12])
			4'h0: if (cpu_addr[11:1] == 11'd0) begin sel_ram = 1'b0; sel_port = 1'b1; end
			4'h8, 4'h9: if (ctrl_a[3]) begin sel_ram = 1'b0; sel_rom = 1'b1; mem_addr = {1'b1, cpu_addr}; end           // $38000
			4'hA, 4'hB:
				if (ctrl_a[4])           begin sel_ram = 1'b0; sel_rom = 1'b1; mem_addr = {1'b1, cpu_addr}; end         // $3A000
				else if (loram && hiram) begin sel_ram = 1'b0; sel_rom = 1'b1; mem_addr = {1'b0, cpu_addr}; end         // $2A000
			4'hC: if (ctrl_a[5])         begin sel_ram = 1'b0; sel_rom = 1'b1; mem_addr = {1'b0, cpu_addr}; end         // $2C000
			4'hD:
				if (loram || hiram) begin
					sel_ram = 1'b0;
					if (charen) sel_io = 1'b1;
					else begin sel_rom = 1'b1; mem_addr = {1'b0, cpu_addr}; end                                        // $2D000
				end
			4'hE, 4'hF:
				if (ctrl_a[7])  begin sel_ram = 1'b0; sel_rom = 1'b1; mem_addr = {1'b1, cpu_addr}; end                  // $3E000
				else if (hiram) begin sel_ram = 1'b0; sel_rom = 1'b1; mem_addr = {1'b0, cpu_addr}; end                  // $2E000
			default: ;
		endcase
		// writes always land in the RAM underneath a ROM
		if (cpu_we && sel_rom && !cpu_far) begin sel_rom = 1'b0; sel_ram = 1'b1; mem_addr = {1'b0, cpu_addr}; end
	end
end

// I/O area decode
logic io_vic, io_fdc, io_pal, io_sid, io_uart, io_dma, io_cram, io_cia1, io_cia2, io_math, io_hyp, io_rec, io_aud;
always_comb begin
	io_vic = 0; io_fdc = 0; io_pal = 0; io_sid = 0; io_uart = 0; io_dma = 0; io_cram = 0; io_cia1 = 0; io_cia2 = 0;
	io_math = 0; io_hyp = 0; io_rec = 0; io_aud = 0;
	if (sel_io) begin
		case (io_addr[11:8])
			4'h0: begin
				if (!vic3_mode || io_addr[7] == 1'b0) io_vic = 1'b1;
				else if (io_addr[7:5] == 3'b100) io_fdc = 1'b1;
				else io_rec = 1'b1;                                  // $D0A0-$D0FF RAM expansion controller
			end
			4'h1, 4'h2, 4'h3: if (vic3_mode) io_pal = 1'b1; else io_vic = 1'b1;
			4'h4, 4'h5: io_sid = 1'b1;
			4'h6: if (gs_mode && io_addr[7:6] == 2'b01) io_hyp = 1'b1; else io_uart = 1'b1;    // $D640-$D67F
			4'h7: begin
				if (gs_mode && (io_addr[7:0] == 8'h0F || io_addr[7:0] >= 8'h68)) io_math = 1'b1;
				else if (gs_mode && io_addr[7:0] >= 8'h11 && io_addr[7:0] < 8'h60) io_aud = 1'b1;   // audio DMA
				else io_dma = 1'b1;
			end
			4'h8, 4'h9, 4'hA, 4'hB: io_cram = 1'b1;
			4'hC: if (ctrl_a[0]) io_cram = 1'b1; else io_cia1 = 1'b1;
			4'hD: if (ctrl_a[0]) io_cram = 1'b1; else io_cia2 = 1'b1;
			default: if (ctrl_a[0]) io_cram = 1'b1;
		endcase
	end
end

wire        ram_sel  = sel_ram || io_cram;
wire [16:0] ram_addr = io_cram ? {6'b111111, io_addr[10:0]} : mem_addr;   // colour RAM = $1F800
wire        slow_dev = io_sid || io_cia1 || io_cia2;

// ------------------------------------------------------------------ bus cycle
// One access per cycle.  FAST: 9 clk (3.5 MHz) or 4 / 2 clk with turbo, slow: one
// full 1 MHz phase.
// CIA / SID accesses are stretched to cover exactly one phi2 period.
// program loader state (see below)
logic        prg_pause, prg_we, prg_was;
logic [15:0] prg_addr, prg_load, prg_end;
logic  [7:0] prg_data;
logic  [2:0] prg_ptr;       // end pointer bytes still to write

// MEGA65 audio DMA sample fetches borrow single clocks between CPU / DMA accesses
logic        aud_req;
logic [23:0] aud_addr;
logic  [1:0] aud_sel;
wire         aud_gnt;

typedef enum logic [1:0] { C_RUN, C_SYNC, C_SLOW, C_XRAM } cyc_t;
cyc_t       cyc_state;
logic [3:0] cyc;
logic       bus_ce;
logic       slow_cs;
logic       force_fast;          // MEGA65 "40 MHz" request: run at the core's top speed (16 MHz)
wire        fast = ctrl_b[6] || force_fast;
wire  [3:0] fast_len = force_fast ? 4'd0 : (turbo == 2'd0) ? 4'd7 : (turbo == 2'd1) ? 4'd2 : 4'd0;

always_ff @(posedge clk) begin
	bus_ce <= 1'b0;
	if (reset) begin
		cyc_state <= C_RUN; cyc <= '0; slow_cs <= 1'b0;
	end
	else if (bus_ce) slow_cs <= 1'b0;
	else if (dma_setup || prg_pause || hyp_busy || aud_gnt) cyc <= '0;   // DMA addresses not valid yet / program being loaded / hypervisor trap
	else begin
		case (cyc_state)
			C_RUN: begin
				if (cyc != 4'd15) cyc <= cyc + 4'd1;
				if (slow_dev) begin
					if (cyc >= 4'd1) cyc_state <= C_SYNC;
				end
				else if (sel_xram) begin
					if (cyc >= 4'd1) cyc_state <= C_XRAM;
				end
				else if (fast ? (cyc >= fast_len) : (cyc >= 4'd3 && ph == 5'd30)) begin
					bus_ce <= 1'b1; cyc <= '0;
				end
			end
			C_SYNC: if (ph == 5'd31) begin cyc_state <= C_SLOW; slow_cs <= 1'b1; end
			C_SLOW: if (ph == 5'd31) begin
				// the device sees phi2_n on this edge; its read data is valid next clk
				bus_ce <= 1'b1; cyc <= '0; cyc_state <= C_RUN;
			end
			C_XRAM: if (xram_ack) begin bus_ce <= 1'b1; cyc <= '0; cyc_state <= C_RUN; end
		endcase
	end
end

assign aud_gnt = aud_req && cyc_state == C_RUN && !bus_ce && !prg_we && !ld_wr;
always_ff @(posedge clk) aud_sel <= aud_addr[18:17];

assign xram_req  = (cyc_state == C_XRAM);
assign xram_we   = bus_we;
assign xram_addr = xaddr;
assign xram_din  = bus_dout;

// RAM expansion controller: only the "no expansion" flag (bit 7) matters to the ROM
logic [6:0] rec_reg;
always_ff @(posedge clk) begin
	if (reset) rec_reg <= '0;
	else if (io_wr && io_rec && io_addr[7:0] == 8'hA0) rec_reg <= bus_dout[6:0];
end

assign cpu_ce = bus_ce && !dma_busy;
assign dma_ce = bus_ce && dma_busy;

wire io_wr = bus_ce && bus_we;
wire io_rd = bus_ce && !bus_we;

// ------------------------------------------------------------------ program loader
// A .PRG is copied into chip RAM bank 0 at the address in its first two bytes
// while the CPU and DMA are held between bus cycles.  Afterwards BASIC is
// told where the program ends: $82/$83 for a C65 BASIC program ($2001),
// $2D-$32 for a C64 one ($0801, after GO64).  Other load addresses (machine
// code) are left alone for SYS.

always_ff @(posedge clk) begin
	prg_we  <= 1'b0;
	prg_was <= prg_dl;
	if (prg_dl) begin
		prg_pause <= 1'b1;
		prg_ptr   <= 3'd0;
		if (prg_wr) begin
			if (prg_ofs == 16'd0)      prg_load[7:0]  <= prg_byte;
			else if (prg_ofs == 16'd1) prg_load[15:8] <= prg_byte;
			else begin
				prg_addr <= prg_load + prg_ofs - 16'd2;
				prg_data <= prg_byte;
				prg_we   <= 1'b1;
				prg_end  <= prg_load + prg_ofs - 16'd1;
			end
		end
	end
	else if (prg_was) begin
		// download finished: write the end pointer(s)
		prg_ptr <= (prg_load == 16'h2001) ? 3'd2 : (prg_load == 16'h0801) ? 3'd6 : 3'd0;
		if (prg_load != 16'h2001 && prg_load != 16'h0801) prg_pause <= 1'b0;
	end
	else if (prg_ptr != 3'd0 && !prg_we) begin
		prg_ptr <= prg_ptr - 3'd1;
		prg_we  <= 1'b1;
		if (prg_load == 16'h2001) begin
			// ptr 2: $83 = high byte, ptr 1: $82 = low byte
			prg_addr <= 16'h0083 - {15'd0, prg_ptr[0]};
			prg_data <= prg_ptr[0] ? prg_end[7:0] : prg_end[15:8];
		end
		else begin
			// ptr 6..1: $2D lo, $2E hi, $2F lo, $30 hi, $31 lo, $32 hi
			prg_addr <= 16'h002D + {13'd0, 3'd6 - prg_ptr};
			prg_data <= prg_ptr[0] ? prg_end[15:8] : prg_end[7:0];
		end
		if (prg_ptr == 3'd1) prg_pause <= 1'b0;
	end
	if (reset && !prg_dl) begin prg_pause <= 1'b0; prg_ptr <= 3'd0; end
end

// ------------------------------------------------------------------ memory
logic  [7:0] ram_q, ram2_q, wom_q, rom_q, vram_q, vram1_q, vram2_q, vrom_q, vrom1_q, vwom_q, cram2_q, vcram2_q, sdbuf_q;

// $FFD6E00-$FFD6FFF: the MEGA65 SD card sector buffer; the hypervisor DOS
// stand-in reads the data file into it
dpram #(9, 8) sdbuf (
	.clk(clk),
	.a_addr(mem_addr[8:0]), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_sdbuf), .a_q(sdbuf_q),
	.b_addr(sd_buff_addr), .b_din(sd_buff_dout), .b_we(sd_buff_wr && dfile_ack), .b_q()
);

// STA $D640 in MEGA65 mode: a hypervisor DOS call
m65_hyppo hyppo (
	.clk(clk), .reset(reset),
	.trap(io_wr && io_hyp && io_addr[5:0] == 6'd0), .fn(bus_dout),
	.cpu_a(dbg_a), .cpu_x(dbg_x), .cpu_y(dbg_y),
	.busy(hyp_busy), .load(hyp_load),
	.res_a(hyp_a), .res_x(hyp_x), .res_y(hyp_y), .res_c(hyp_c),
	.img_mounted(dfile_mounted), .img_size(img_size),
	.sd_lba(dfile_lba), .sd_rd(dfile_rd), .sd_ack(dfile_ack), .buf_clear()
);
logic [18:0] vaddr;
logic  [1:0] vsel;
logic        wom_loaded;

// $40000-$5FFFF: the extra chip RAM MEGA65 ROMs expect (graphics, sprites)
dpram #(17, 8) ram2 (
	.clk(clk),
	.a_addr(aud_gnt ? aud_addr[16:0] : mem_addr), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_ram2), .a_q(ram2_q),
	.b_addr(vaddr[16:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vram2_q)
);

// $FF7E000: 4K character set RAM.  MEGA65 ROMs copy their font here and the
// video chip displays it in place of the character ROM.
dpram #(12, 8) wom (
	.clk(clk),
	.a_addr(mem_addr[11:0]), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_wom), .a_q(wom_q),
	.b_addr(vaddr[11:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vwom_q)
);

// $FF80800-$FF87FFF: colour RAM beyond the C65's 2K, making the MEGA65's 32K
// (80 column full-colour and larger screens).  The video chip sees it at $60000.
dpram #(15, 8) cram2 (
	.clk(clk),
	.a_addr(mem_addr[14:0]), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_cram2), .a_q(cram2_q),
	.b_addr(vaddr[14:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vcram2_q)
);

assign rom_wr = bus_ce && bus_we && sel_romw;

always_ff @(posedge clk) vsel <= vaddr[18:17];
// $20000-$3FFFF is the ROM (RAM to MEGA65 programs, which keep graphics there)
assign vram_q = (vsel == 2'd2) ? vram2_q : (vsel == 2'd3) ? vcram2_q : (vsel == 2'd1) ? vrom1_q : vram1_q;
assign vrom_q = wom_loaded ? vwom_q : vrom1_q;

// use the character set RAM once the ROM has filled it
always_ff @(posedge clk) begin
	if (reset) wom_loaded <= 1'b0;
	else if (bus_ce && bus_we && sel_wom && mem_addr[11:0] == 12'hFFF) wom_loaded <= 1'b1;
end

dpram #(17, 8) ram (
	.clk(clk),
	.a_addr(prg_we ? {1'b0, prg_addr} : aud_gnt ? aud_addr[16:0] : ram_addr), .a_din(prg_we ? prg_data : bus_dout),
	.a_we(prg_we || (bus_ce && bus_we && ram_sel)), .a_q(ram_q),
	.b_addr(vaddr[16:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vram1_q)
);

dpram #(17, 8) rom (
	.clk(clk),
	.a_addr(ld_wr ? ld_addr : rs_wr ? rrom_addr : aud_gnt ? aud_addr[16:0] : mem_addr),
	.a_din(ld_wr ? ld_data : rs_wr ? rs_data : bus_dout), .a_we(ld_wr || rs_wr || rom_wr), .a_q(rom_q),
	.b_addr(vaddr[16:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vrom1_q)
);

// ------------------------------------------------------------------ CPU port
always_ff @(posedge clk) begin
	if (reset) begin port_ddr <= '0; port_dat <= '0; force_fast <= 1'b0; end
	else if (io_wr && sel_port) begin
		// MEGA65: writing 65 / 64 to address 0 switches full CPU speed on / off
		// and is not a data direction write
		if (!cpu_addr[0] && gs_mode && bus_dout[7:1] == 7'b0100000) force_fast <= bus_dout[0];
		else if (cpu_addr[0]) port_dat <= bus_dout;
		else port_ddr <= bus_dout;
	end
end

// ------------------------------------------------------------------ VIC-III
logic [7:0] vic_dout, pal_dout;
logic       vic_irq_n;
logic [1:0] vic_bank;
logic       key_a5, key_47;

// VIC-II mode mirrors $D000-$D03F through $D3FF and hides registers $30+
wire [6:0] vic_reg = vic3_mode ? io_addr[6:0] : {1'b0, io_addr[5:0]};

// $D02F KEY register: $A5 then $96 selects VIC-III I/O mode
always_ff @(posedge clk) begin
	if (reset) begin vic3_mode <= 1'b0; key_a5 <= 1'b0; key_47 <= 1'b0; gs_mode <= 1'b0; end
	else if (io_wr && io_vic && vic_reg == 7'h2F) begin
		key_a5 <= (bus_dout == 8'hA5);
		key_47 <= (bus_dout == 8'h47);
		if (bus_dout == 8'h96 && key_a5)      vic3_mode <= 1'b1;
		else if (bus_dout == 8'h53 && key_47 && m65_ext) begin vic3_mode <= 1'b1; gs_mode <= 1'b1; end   // MEGA65 key
		// with the extensions off, $47,$53 is just a wrong key, as on a real C65
		else if (bus_dout != 8'hA5 && bus_dout != 8'h47) vic3_mode <= 1'b0;
	end
end

vic3 vic (
	.clk(clk), .reset(reset), .ce_pix(ce640), .pix_ce(ce_pix), .ntsc(ntsc),
	.vic3_mode(vic3_mode), .vic4_mode(gs_mode),
	.reg_addr(vic_reg), .reg_we(io_wr && io_vic), .reg_re(io_rd && io_vic),
	.reg_din(bus_dout), .reg_dout(vic_dout),
	.pal_addr(io_addr[9:0]), .pal_we(io_wr && io_pal), .pal_dout(pal_dout),
	.ctrl_a(ctrl_a), .ctrl_b(ctrl_b), .irq_n(vic_irq_n),
	.vic_bank(vic_bank), .vaddr(vaddr), .vram_q(vram_q), .vrom_q(vrom_q),
	.r(r), .g(g), .b(b), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
	.field(field), .raster()
);

// ------------------------------------------------------------------ CIAs
logic [7:0] cia1_dout, cia2_dout;
logic [7:0] cia1_pa_out, cia1_pb_out, cia2_pa_out, cia2_pb_out;
logic [7:0] kb_rows, kb_cols;
logic       cia1_irq_n, cia2_irq_n, restore_n;
logic       tod;

// 50/60 Hz time-of-day tick
logic [19:0] tod_cnt;
wire  [19:0] tod_half = ntsc ? 20'd272727 : 20'd315279;   // clk / (2 * 60) or clk / (2 * 50)
always_ff @(posedge clk) begin
	if (reset) begin tod_cnt <= '0; tod <= 1'b0; end
	else if (tod_cnt == tod_half - 20'd1) begin tod_cnt <= '0; tod <= ~tod; end
	else tod_cnt <= tod_cnt + 20'd1;
end

// 1351 proportional mouse: position on the SID POT lines, left button =
// fire, right button = up, on the control port chosen in the OSD
logic [7:0] mouse_x, mouse_y;
logic [1:0] mouse_btn;

c1351 mouse (
	.clk_sys(clk), .reset(reset), .ps2_mouse(ps2_mouse),
	.potX(mouse_x), .potY(mouse_y), .button(mouse_btn)
);

wire [4:0] mouse_joy = {mouse_btn[0], 3'b000, mouse_btn[1]};
wire [4:0] joy1_m = joy1 | (mouse_port == 2'd1 ? mouse_joy : 5'd0);
wire [4:0] joy2_m = joy2 | (mouse_port == 2'd2 ? mouse_joy : 5'd0);

// the POT lines of a port are only connected while CIA1 PA6 (port 1) / PA7 (port 2) is high
wire       pot_mouse = (mouse_port == 2'd1 && cia1_pa_out[6]) || (mouse_port == 2'd2 && cia1_pa_out[7]);
// (c1351 delivers the values inverted, as the MiSTer C64 core expects)
wire [7:0] pot_x = pot_mouse ? ~mouse_x : 8'hFF;
wire [7:0] pot_y = pot_mouse ? ~mouse_y : 8'hFF;

wire [7:0] cia1_pa_in = cia1_pa_out & kb_cols & {3'b111, ~joy2_m};
wire [7:0] cia1_pb_in = cia1_pb_out & kb_rows & {3'b111, ~joy1_m};

mos6526_8520 cia1 (
	.mode(2'd0), .clk(clk), .phi2_p(phi2_p), .phi2_n(phi2_n), .res_n(~reset),
	.cs_n(~(slow_cs && io_cia1)), .rw(~bus_we), .rs(io_addr[3:0]),
	.db_in(bus_dout), .db_out(cia1_dout),
	.pa_in(cia1_pa_in), .pa_out(cia1_pa_out), .pa_oe(),
	.pb_in(cia1_pb_in), .pb_out(cia1_pb_out), .pb_oe(),
	.flag_n(1'b1), .pc_n(), .tod(tod), .sp_in(1'b1), .sp_out(), .cnt_in(1'b1), .cnt_out(),
	.irq_n(cia1_irq_n)
);

// CIA2 port A: [1:0] video bank, [3] ATN out, [4] CLK out, [5] DATA out,
// [6] CLK in, [7] DATA in.  No external IEC devices yet: the bus just
// reflects what the C65 itself drives.
// CIA2 port A: [3] ATN out, [4] CLK out, [5] DATA out (1 pulls the line low),
// [6] CLK in, [7] DATA in.  The bus is wired-AND of the C65 and the drives.
assign iec_atn_o  = ~cia2_pa_out[3];
assign iec_clk_o  = ~cia2_pa_out[4];
assign iec_data_o = ~cia2_pa_out[5];
wire [7:0] cia2_pa_in = {iec_data_o & iec_data_i, iec_clk_o & iec_clk_i, cia2_pa_out[5:0]};

mos6526_8520 cia2 (
	.mode(2'd0), .clk(clk), .phi2_p(phi2_p), .phi2_n(phi2_n), .res_n(~reset),
	.cs_n(~(slow_cs && io_cia2)), .rw(~bus_we), .rs(io_addr[3:0]),
	.db_in(bus_dout), .db_out(cia2_dout),
	.pa_in(cia2_pa_in), .pa_out(cia2_pa_out), .pa_oe(),
	.pb_in(cia2_pb_out), .pb_out(cia2_pb_out), .pb_oe(),
	.flag_n(1'b1), .pc_n(), .tod(tod), .sp_in(1'b1), .sp_out(), .cnt_in(1'b1), .cnt_out(),
	.irq_n(cia2_irq_n)
);

assign vic_bank = ~cia2_pa_out[1:0];

// ------------------------------------------------------------------ UART / port E
// The UART itself is not implemented; $D607/$D608 is the port that selects
// the extra keyboard column.
logic [7:0] uart_regs [16];
wire        m65_reg = gs_mode && (io_addr[7:4] != 4'd0);    // $D610-$D63F in MEGA65 mode
logic [7:0] uart_dout;
wire  [7:0] porte = uart_regs[7] | ~uart_regs[8];

// MEGA65 keyboard matrix peek: $D614 selects a column, $D613 reads it (0 = pressed);
// $D611 holds the modifier keys (1 = pressed)
logic [71:0] kb_matrix;
logic        kb_left, kb_up;
logic  [3:0] kms;
wire   [7:0] kmpeek = (kms < 4'd9) ? ~kb_matrix[{kms, 3'b000} +: 8] : 8'hFF;

// MEGA65 typing queue ($D610): the MEGA65 keyboard turns key presses into
// codes (ASCII letters and symbols, C64 codes for RETURN, DEL, the cursor
// keys, HOME, RUN/STOP and F1-F14) in a queue that BASIC 65 reads:
//   $D610  the oldest key as ASCII (0 = none); writing drops it
//   $D619  the same key as PETSCII ($FF = none); writing drops it
//   $D60A  SHIFT / CTRL / MEGA at that key, bit 7 = queue not empty;
//          writing 0 to bit 7 empties the queue
// A held key repeats after half a second, about 16 times a second.
function automatic [7:0] m65_key_code(input logic [6:0] idx, input logic shift);
	m65_key_code = 8'h00;
	case (idx)
		7'd0: m65_key_code = shift ? 8'h94 : 8'h14;   // DEL
		7'd1: m65_key_code = shift ? 8'h0D : 8'h0D;   // RETURN
		7'd2: m65_key_code = shift ? 8'h9D : 8'h1D;   // RIGHT
		7'd3: m65_key_code = shift ? 8'hF8 : 8'hF7;   // F7
		7'd4: m65_key_code = shift ? 8'hF2 : 8'hF1;   // F1
		7'd5: m65_key_code = shift ? 8'hF4 : 8'hF3;   // F3
		7'd6: m65_key_code = shift ? 8'hF6 : 8'hF5;   // F5
		7'd7: m65_key_code = shift ? 8'h91 : 8'h11;   // DOWN
		7'd8: m65_key_code = shift ? 8'h23 : 8'h33;   // 3
		7'd9: m65_key_code = shift ? 8'h57 : 8'h77;   // W
		7'd10: m65_key_code = shift ? 8'h41 : 8'h61;   // A
		7'd11: m65_key_code = shift ? 8'h24 : 8'h34;   // 4
		7'd12: m65_key_code = shift ? 8'h5A : 8'h7A;   // Z
		7'd13: m65_key_code = shift ? 8'h53 : 8'h73;   // S
		7'd14: m65_key_code = shift ? 8'h45 : 8'h65;   // E
		7'd16: m65_key_code = shift ? 8'h25 : 8'h35;   // 5
		7'd17: m65_key_code = shift ? 8'h52 : 8'h72;   // R
		7'd18: m65_key_code = shift ? 8'h44 : 8'h64;   // D
		7'd19: m65_key_code = shift ? 8'h26 : 8'h36;   // 6
		7'd20: m65_key_code = shift ? 8'h43 : 8'h63;   // C
		7'd21: m65_key_code = shift ? 8'h46 : 8'h66;   // F
		7'd22: m65_key_code = shift ? 8'h54 : 8'h74;   // T
		7'd23: m65_key_code = shift ? 8'h58 : 8'h78;   // X
		7'd24: m65_key_code = shift ? 8'h27 : 8'h37;   // 7
		7'd25: m65_key_code = shift ? 8'h59 : 8'h79;   // Y
		7'd26: m65_key_code = shift ? 8'h47 : 8'h67;   // G
		7'd27: m65_key_code = shift ? 8'h28 : 8'h38;   // 8
		7'd28: m65_key_code = shift ? 8'h42 : 8'h62;   // B
		7'd29: m65_key_code = shift ? 8'h48 : 8'h68;   // H
		7'd30: m65_key_code = shift ? 8'h55 : 8'h75;   // U
		7'd31: m65_key_code = shift ? 8'h56 : 8'h76;   // V
		7'd32: m65_key_code = shift ? 8'h29 : 8'h39;   // 9
		7'd33: m65_key_code = shift ? 8'h49 : 8'h69;   // I
		7'd34: m65_key_code = shift ? 8'h4A : 8'h6A;   // J
		7'd35: m65_key_code = shift ? 8'h30 : 8'h30;   // 0
		7'd36: m65_key_code = shift ? 8'h4D : 8'h6D;   // M
		7'd37: m65_key_code = shift ? 8'h4B : 8'h6B;   // K
		7'd38: m65_key_code = shift ? 8'h4F : 8'h6F;   // O
		7'd39: m65_key_code = shift ? 8'h4E : 8'h6E;   // N
		7'd40: m65_key_code = shift ? 8'h2B : 8'h2B;   // PLUS
		7'd41: m65_key_code = shift ? 8'h50 : 8'h70;   // P
		7'd42: m65_key_code = shift ? 8'h4C : 8'h6C;   // L
		7'd43: m65_key_code = shift ? 8'h2D : 8'h2D;   // MINUS
		7'd44: m65_key_code = shift ? 8'h3E : 8'h2E;   // DOT
		7'd45: m65_key_code = shift ? 8'h5B : 8'h3A;   // COLON
		7'd46: m65_key_code = shift ? 8'h40 : 8'h40;   // AT
		7'd47: m65_key_code = shift ? 8'h3C : 8'h2C;   // COMMA
		7'd48: m65_key_code = shift ? 8'h5C : 8'h5C;   // POUND
		7'd49: m65_key_code = shift ? 8'h2A : 8'h2A;   // STAR
		7'd50: m65_key_code = shift ? 8'h5D : 8'h3B;   // SEMI
		7'd51: m65_key_code = shift ? 8'h93 : 8'h13;   // HOME
		7'd53: m65_key_code = shift ? 8'h3D : 8'h3D;   // EQUAL
		7'd54: m65_key_code = shift ? 8'h5E : 8'h5E;   // UPARROW
		7'd55: m65_key_code = shift ? 8'h3F : 8'h2F;   // SLASH
		7'd56: m65_key_code = shift ? 8'h21 : 8'h31;   // 1
		7'd57: m65_key_code = shift ? 8'h5F : 8'h5F;   // LEFTARROW
		7'd59: m65_key_code = shift ? 8'h22 : 8'h32;   // 2
		7'd60: m65_key_code = shift ? 8'hA0 : 8'h20;   // SPACE
		7'd62: m65_key_code = shift ? 8'h51 : 8'h71;   // Q
		7'd63: m65_key_code = shift ? 8'h03 : 8'h03;   // STOP
		7'd65: m65_key_code = shift ? 8'h09 : 8'h09;   // TAB
		7'd67: m65_key_code = shift ? 8'h1F : 8'h1F;   // HELP
		7'd68: m65_key_code = shift ? 8'hFA : 8'hF9;   // F9
		7'd69: m65_key_code = shift ? 8'hFC : 8'hFB;   // F11
		7'd70: m65_key_code = shift ? 8'hFE : 8'hFD;   // F13
		7'd71: m65_key_code = shift ? 8'h1B : 8'h1B;   // ESC
		default: ;
	endcase
endfunction

logic        kb_event, kb_shift, kb_ctrl, kb_mega;
logic  [6:0] kb_index;
logic  [7:0] kq [8];
logic  [2:0] kq_mod [8];   // {MEGA, CTRL, SHIFT} when the key went down
logic  [2:0] kq_head, kq_tail;
logic  [3:0] kq_n;
logic  [6:0] rep_idx;
logic        rep_shift, rep_ctrl, rep_on;
logic [24:0] rep_cnt;
localparam logic [24:0] REP_DELAY = 25'd15_700_000;   // ~0.5 s
localparam logic [24:0] REP_RATE  = 25'd1_970_000;    // ~16 per second

function automatic [7:0] kq_code(input logic [6:0] idx, input logic shift, input logic ctrl);
	logic [7:0] c;
	c = m65_key_code(idx, shift);
	if (ctrl && ((c >= 8'h41 && c <= 8'h5A) || (c >= 8'h61 && c <= 8'h7A))) c = c & 8'h1F;
	kq_code = c;
endfunction

// ASCII to PETSCII as the MEGA65 gives it at $D619
function automatic [7:0] kq_petscii(input logic [7:0] a);
	if (a >= 8'h61 && a <= 8'h7A) kq_petscii = a - 8'h20;          // a-z: unshifted letters
	else if (a >= 8'h41 && a <= 8'h5A) kq_petscii = a + 8'h80;     // A-Z: shifted letters
	else case (a)
		8'hF1: kq_petscii = 8'd133; 8'hF3: kq_petscii = 8'd134; 8'hF5: kq_petscii = 8'd135; 8'hF7: kq_petscii = 8'd136;
		8'hF2: kq_petscii = 8'd137; 8'hF4: kq_petscii = 8'd138; 8'hF6: kq_petscii = 8'd139; 8'hF8: kq_petscii = 8'd140;
		8'hF9: kq_petscii = 8'd16;  8'hFA: kq_petscii = 8'd21;  8'hFB: kq_petscii = 8'd22;  8'hFC: kq_petscii = 8'd23;
		8'hFD: kq_petscii = 8'd24;  8'hFE: kq_petscii = 8'd25;  8'h1F: kq_petscii = 8'd132;      // HELP
		default: kq_petscii = a;
	endcase
endfunction

wire kq_pop   = io_wr && gs_mode && ((io_uart && io_addr[7:0] == 8'h10) || (io_uart && io_addr[7:0] == 8'h19));
wire kq_flush = io_wr && gs_mode && io_uart && io_addr[7:0] == 8'h0A && !bus_dout[7];

always_ff @(posedge clk) begin
	logic [7:0] c;
	logic       push;
	if (reset) begin kq_head <= '0; kq_tail <= '0; kq_n <= '0; rep_on <= 1'b0; end
	else begin
		push = 1'b0; c = 8'h00;
		if (kb_event) begin
			c = kq_code(kb_index, kb_shift, kb_ctrl);
			push = (c != 8'h00);
			rep_idx <= kb_index; rep_shift <= kb_shift; rep_ctrl <= kb_ctrl;
			rep_on <= (c != 8'h00); rep_cnt <= '0;
		end
		else if (rep_on) begin
			if (!kb_matrix[rep_idx]) rep_on <= 1'b0;
			else if (rep_cnt == REP_DELAY) begin
				c = kq_code(rep_idx, rep_shift, rep_ctrl);
				push = 1'b1;
				rep_cnt <= REP_DELAY - REP_RATE;
			end
			else rep_cnt <= rep_cnt + 25'd1;
		end
		if (push && kq_n != 4'd8) begin
			kq[kq_tail] <= c;
			kq_mod[kq_tail] <= kb_event ? {kb_mega, kb_ctrl, kb_shift} : {1'b0, rep_ctrl, rep_shift};
			kq_tail <= kq_tail + 3'd1;
		end
		if (kq_pop && kq_n != 4'd0) kq_head <= kq_head + 3'd1;
		kq_n <= kq_n + ((push && kq_n != 4'd8) ? 4'd1 : 4'd0) - ((kq_pop && kq_n != 4'd0) ? 4'd1 : 4'd0);
		if (kq_flush) begin kq_head <= '0; kq_tail <= '0; kq_n <= '0; end
	end
end

always_ff @(posedge clk) begin
	if (reset) begin for (int i = 0; i < 16; i++) uart_regs[i] <= '0; kms <= '0; end
	else if (io_wr && io_uart && !m65_reg) uart_regs[io_addr[3:0]] <= bus_dout;
	else if (io_wr && io_uart && io_addr[7:0] == 8'h14) kms <= bus_dout[3:0];
end

// $D600-$D606: the serial port
wire        ser_sel = io_uart && !m65_reg && (io_addr[3:0] < 4'd7);
logic [7:0] ser_dout;
logic       ser_irq_n;
c65_uart serial (
	.clk(clk), .reset(reset), .ntsc(ntsc),
	.reg_addr(io_addr[2:0]), .reg_we(io_wr && ser_sel), .reg_re(io_rd && ser_sel),
	.reg_din(bus_dout), .reg_dout(ser_dout), .irq_n(ser_irq_n),
	.rxd(uart_rxd), .txd(uart_txd)
);

always_comb begin
	case (io_addr[3:0])
		4'd7:    uart_dout = porte;
		default: uart_dout = (io_addr[3:0] < 4'd7) ? ser_dout : uart_regs[io_addr[3:0]];
	endcase
	// $D60F: cursor left / up held, "real hardware"
	if (gs_mode && io_addr[7:0] == 8'h0F) uart_dout = {2'b00, 1'b1, 3'b000, kb_up, kb_left};
	// $D60A: the typing queue's modifiers and "not empty"
	if (gs_mode && io_addr[7:0] == 8'h0A)
		uart_dout = {kq_n != 4'd0, 3'b000, kq_mod[kq_head][2], kq_mod[kq_head][1], 1'b0, kq_mod[kq_head][0]};
	// $D629 is the MEGA65 hardware model: answer as a MEGA65 R3
	if (m65_reg) case (io_addr[7:0])
		8'h29:   uart_dout = 8'h03;
		8'h13:   uart_dout = kmpeek;
		8'h10:   uart_dout = (kq_n != 4'd0) ? kq[kq_head] : 8'h00;
		8'h19:   uart_dout = (kq_n != 4'd0) ? kq_petscii(kq[kq_head]) : 8'hFF;
		// modifier keys: L/R shift, CTRL, MEGA (C=), ALT, NO SCROLL, CAPS LOCK
		8'h11:   uart_dout = {1'b0, ~capslock_n, kb_matrix[64], kb_matrix[66], kb_matrix[61], kb_matrix[58], kb_matrix[52], kb_matrix[15]};
		8'h14:   uart_dout = {4'd0, kms};
		default: uart_dout = 8'h00;
	endcase
end

c65_keyboard keyboard (
	.clk(clk), .reset(reset), .layout(kbd_layout), .ps2_key(ps2_key),
	.col_sel(cia1_pa_out), .col8_sel(porte[1]), .row_drive(cia1_pb_out),
	.row_in(kb_rows), .col_in(kb_cols),
	.restore_n(restore_n), .capslock_n(capslock_n),
	.matrix(kb_matrix), .crsr_left(kb_left), .crsr_up(kb_up),
	.key_event(kb_event), .key_index(kb_index), .key_shift(kb_shift), .key_ctrl(kb_ctrl), .key_mega(kb_mega)
);

// ------------------------------------------------------------------ F011 floppy controller
logic [7:0] fdc_dout, fdcbuf_q;
logic       fdc_irq_n;

f011 fdc (
	.clk(clk), .reset(reset),
	.reg_addr(io_addr[4:0]), .reg_we(io_wr && io_fdc), .reg_re(io_rd && io_fdc),
	.reg_din(bus_dout), .reg_dout(fdc_dout), .irq_n(fdc_irq_n),
	.dir_sel(sel_fdcbuf), .dir_addr(mem_addr[8:0]), .dir_we(bus_ce && bus_we && sel_fdcbuf), .dir_q(fdcbuf_q),
	.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
	.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr), .led(drive_led)
);

// ------------------------------------------------------------------ SIDs
logic [7:0] sid_dout;
logic [17:0] sid_l, sid_r;

`ifdef C65_NO_SID
// simulation stub: only the POT registers ($19 / $1A) answer
assign sid_dout = (io_addr[4:0] == 5'h19) ? pot_x : (io_addr[4:0] == 5'h1A) ? pot_y : 8'h00;
assign sid_l = '0;
assign sid_r = '0;
`else
sid_top #(.MULTI_FILTERS(1), .DUAL(1)) sid (
	.reset(reset), .clk(clk), .ce_1m(phi2_n),
	.cs({slow_cs && io_sid && io_addr[5], slow_cs && io_sid && !io_addr[5]}),
	.we(bus_we), .addr(io_addr[4:0]), .data_in(bus_dout), .data_out(sid_dout),
	.fc_offset_l(13'd0), .pot_x_l(pot_x), .pot_y_l(pot_y), .ext_in_l(18'd0), .audio_l(sid_r),
	.fc_offset_r(13'd0), .pot_x_r(pot_x), .pot_y_r(pot_y), .ext_in_r(18'd0), .audio_r(sid_l),
	.filter_en(2'b11), .mode(2'b11), .cfg(4'd0),
	.ld_clk(clk), .ld_addr(12'd0), .ld_data(16'd0), .ld_wr(1'b0)
);
`endif

// ------------------------------------------------------------------ MEGA65 extras
logic [7:0] math_dout, rtc_dout, aud_dout;
logic signed [15:0] aud_l, aud_r;

m65_audio audio_dma (
	.clk(clk), .reset(reset),
	.reg_addr(io_addr[6:0]), .reg_we(io_wr && io_aud), .reg_din(bus_dout), .reg_dout(aud_dout),
	.fetch_req(aud_req), .fetch_addr(aud_addr), .fetch_gnt(aud_gnt),
	.fetch_q((aud_sel == 2'd0) ? ram_q : (aud_sel == 2'd1) ? rom_q : ram2_q),
	.out_l(aud_l), .out_r(aud_r)
);

// SIDs plus audio DMA, saturated
function automatic [17:0] mix(input logic [17:0] a, input logic signed [15:0] b);
	logic signed [18:0] t;
	t = $signed({a[17], a}) + $signed({b[15], b, 2'b00});
	mix = (t > 19'sh1FFFF) ? 18'h1FFFF : (t < -19'sh20000) ? 18'h20000 : t[17:0];
endfunction
assign audio_l = mix(sid_l, aud_l);
assign audio_r = mix(sid_r, aud_r);
wire  [3:0] fa_rtc = dma_busy ? dma_addr[3:0] : cpu_faddr[3:0];

m65_rtc rtc_clock (
	.clk(clk), .ntsc(ntsc), .rtc(rtc), .reg_addr(fa_rtc), .reg_dout(rtc_dout)
);

m65_math math (
	.clk(clk), .reset(reset),
	.reg_addr(io_addr[7:0]), .reg_we(io_wr && io_math), .reg_din(bus_dout), .reg_dout(math_dout)
);

`ifdef IO_DEBUG
always @(posedge clk) begin
	if (bus_ce && ser_sel)
		$display("SER  %s $D60%01x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[3:0], bus_we ? bus_dout : ser_dout, dbg_pc);
	if (bus_ce && io_hyp)
		$display("HYP  %s $D6%02x = %02x  PC=%04x A=%02x", bus_we ? "wr" : "rd", io_addr[7:0], bus_dout, dbg_pc, dbg_a);
	if (bus_ce && io_vic && vic_reg >= 7'h40)
		$display("VIC4 %s $D0%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_we ? bus_dout : bus_din, dbg_pc);
	if (bus_ce && io_fdc)
		$display("FDC  %s $D0%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_we ? bus_dout : bus_din, dbg_pc);
	if (bus_ce && io_aud)
		$display("AUD  %s $D7%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_we ? bus_dout : bus_din, dbg_pc);
	if (bus_ce && io_dma && io_addr[7:0] > 8'h03)
		$display("DMA+ %s $D7%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_we ? bus_dout : bus_din, dbg_pc);
	if (bus_ce && io_uart && io_addr[7:0] > 8'h0F)
		$display("M65  %s $D6%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_we ? bus_dout : bus_din, dbg_pc);
	if (bus_ce && cpu_far && !dma_busy && !sel_ram && !sel_ram2 && !sel_cram2 && !sel_sdbuf && !sel_fdcbuf && !sel_wom && !sel_rom && !sel_io && !sel_xram && !sel_rtc)
		$display("FAR  %s %07x = %02x  PC=%04x", bus_we ? "wr" : "rd", cpu_faddr, bus_dout, dbg_pc);
end
`endif

// ------------------------------------------------------------------ read mux / interrupts
logic [7:0] io_dout;
always_comb begin
	io_dout = 8'hFF;
	if (io_vic)       io_dout = vic_dout;
	else if (io_pal)  io_dout = pal_dout;
	else if (io_fdc)  io_dout = fdc_dout;
	else if (io_sid)  io_dout = sid_dout;
	else if (io_uart) io_dout = uart_dout;
	else if (io_dma)  io_dout = dma_reg_dout;
	else if (io_math) io_dout = math_dout;
	else if (io_aud)  io_dout = aud_dout;
	else if (io_hyp)  io_dout = 8'h00;
	else if (io_rec)  io_dout = (io_addr[7:0] == 8'hA0) ? {!xram_present, rec_reg} : 8'hFF;
	else if (io_cia1) io_dout = cia1_dout;
	else if (io_cia2) io_dout = cia2_dout;
end

always_comb begin
	if (ram_sel)       bus_din = ram_q;
	else if (sel_ram2) bus_din = ram2_q;
	else if (sel_cram2) bus_din = cram2_q;
	else if (sel_sdbuf) bus_din = sdbuf_q;
	else if (sel_fdcbuf) bus_din = fdcbuf_q;
	else if (sel_wom)  bus_din = wom_q;
	else if (sel_xram) bus_din = xram_dout;
	else if (sel_rtc)  bus_din = rtc_dout;
	else if (sel_rom)  bus_din = rom_q;
	else if (sel_port) bus_din = cpu_addr[0] ? port_val : port_ddr;
	else if (sel_io)   bus_din = io_dout;
	else               bus_din = 8'hFF;
end

// $D705 (enhanced DMA job) only exists in MEGA65 mode
assign dma_reg_we = io_wr && io_dma && (io_addr[7:3] == 5'd0) && ((io_addr[2:0] != 3'd5 && io_addr[2:0] != 3'd7) || gs_mode);
assign dbg_op     = bus_din;

assign irq_n = vic_irq_n & cia1_irq_n & fdc_irq_n & ser_irq_n;
assign nmi_n = cia2_irq_n & restore_n;

endmodule
