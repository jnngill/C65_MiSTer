// Commodore 65 system core (platform independent; wrapped by C65.sv on MiSTer
// and by sim/system/tb.cpp under Verilator).
//
// clk is 32x the 1 MHz phase clock (~31.5 MHz PAL, ~32.7 MHz NTSC).

module c65_core (
	input  logic        clk,
	input  logic        reset,
	input  logic        ntsc,
	input  logic        dma_f018b,
	input  logic  [1:0] turbo,            // CPU speed in FAST mode: 0 = 3.5 MHz, 1 = 8 MHz, 2 = 16 MHz

	// ROM image loader (128K, used while the machine is held in reset)
	input  logic [16:0] ld_addr,
	input  logic  [7:0] ld_data,
	input  logic        ld_wr,

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
	output logic        drive_led,

	// wall-clock time from the host (MiSTer hps_io RTC word), for the MEGA65 clock registers
	input  logic [64:0] rtc,

	// expansion RAM (external memory, request / acknowledge):
	//   $060000-$0FFFFF  banks 6-15, addressed as is (xram_addr[22] = 0)
	//   $400000-$7FFFFF  4 MB reached through DMA (xram_addr[22] = 1)
	input  logic        xram_present,
	output logic        xram_req,         // held until xram_ack
	output logic        xram_we,
	output logic [22:0] xram_addr,
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

cpu4510 cpu (
	.clk(clk), .reset(reset), .ce(cpu_ce),
	.irq_n(irq_n), .nmi_n(nmi_n), .gs(gs_mode),
	.far_sel(cpu_far), .far_addr(cpu_faddr),
	.addr(cpu_addr), .paddr(cpu_paddr), .mapped(cpu_mapped),
	.dout(cpu_dout), .we(cpu_we), .din(bus_din),
	.sync(dbg_sync),
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

logic        sel_ram, sel_ram2, sel_wom, sel_rom, sel_io, sel_port, sel_xram, sel_rtc, sel_cram2;
// a DMA address with the I/O flag only means I/O inside $D000-$DFFF; elsewhere it is plain memory
wire         dma_is_io = dma_io && (dma_addr[15:12] == 4'hD);
logic [22:0] xaddr;
logic [16:0] mem_addr;

always_comb begin
	logic [22:0] pa;
	logic [27:0] fa;       // flat 28-bit address: 45GS02 far pointer or DMA
	logic        flat;
	sel_ram = 1'b0; sel_ram2 = 1'b0; sel_cram2 = 1'b0; sel_wom = 1'b0; sel_rom = 1'b0; sel_io = 1'b0; sel_port = 1'b0;
	sel_xram = 1'b0; sel_rtc = 1'b0;
	mem_addr = '0;
	io_addr  = dma_busy ? dma_addr[11:0] : cpu_far ? cpu_faddr[11:0] : cpu_addr[11:0];
	pa    = {3'd0, cpu_paddr};
	fa    = dma_busy ? dma_addr : cpu_faddr;
	flat  = dma_busy ? !dma_is_io : cpu_far;
	xaddr = flat ? fa[22:0] : pa;

	if (flat) begin
		// flat 28-bit access: a 45GS02 far pointer, or the DMA controller
		mem_addr = fa[16:0];
		if (fa[27:17] == 11'd0)          sel_ram = 1'b1;             // $0000000 chip RAM
		else if (fa[27:17] == 11'd1)     sel_rom = !bus_we;          // $0020000 ROM
		else if (fa[27:17] == 11'd2)     sel_ram2 = 1'b1;            // $0040000 extra chip RAM
		else if (fa[27:22] == 6'd1)      sel_xram = xram_present;    // $0400000 expansion RAM
		else if (fa[27:20] == 8'd0)      sel_xram = xram_present;    // $0060000 banks 6-15
		else if (fa[27:12] == 16'hFF7E)  sel_wom = 1'b1;             // $FF7E000 character set
		else if (fa[27:11] == 17'h1FF00) begin sel_ram = 1'b1; mem_addr = {6'b111111, fa[10:0]}; end   // $FF80000 colour RAM
		else if (fa[27:13] == 15'h7FC0 && fa[12:11] != 2'd3) begin sel_cram2 = 1'b1; mem_addr = {5'd0, fa[11:0] - 12'h800}; end   // $FF80800 more colour RAM
		else if (fa[27:12] == 16'hFFD3)  sel_io = 1'b1;              // $FFD3000 I/O
		else if (fa[27:4] == 24'hFFD711) sel_rtc = 1'b1;             // $FFD7110 real-time clock
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
logic io_vic, io_fdc, io_pal, io_sid, io_uart, io_dma, io_cram, io_cia1, io_cia2, io_math, io_hyp, io_rec;
always_comb begin
	io_vic = 0; io_fdc = 0; io_pal = 0; io_sid = 0; io_uart = 0; io_dma = 0; io_cram = 0; io_cia1 = 0; io_cia2 = 0;
	io_math = 0; io_hyp = 0; io_rec = 0;
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
	else if (dma_setup || prg_pause) cyc <= '0;   // DMA addresses not valid yet / program being loaded
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
logic  [7:0] ram_q, ram2_q, wom_q, rom_q, vram_q, vram1_q, vram2_q, vrom_q, vrom1_q, vwom_q, cram2_q, vcram2_q;
logic [18:0] vaddr;
logic  [1:0] vsel;
logic        wom_loaded;

// $40000-$5FFFF: the extra chip RAM MEGA65 ROMs expect (graphics, sprites)
dpram #(17, 8) ram2 (
	.clk(clk),
	.a_addr(mem_addr), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_ram2), .a_q(ram2_q),
	.b_addr(vaddr[16:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vram2_q)
);

// $FF7E000: 4K character set RAM.  MEGA65 ROMs copy their font here and the
// video chip displays it in place of the character ROM.
dpram #(12, 8) wom (
	.clk(clk),
	.a_addr(mem_addr[11:0]), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_wom), .a_q(wom_q),
	.b_addr(vaddr[11:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vwom_q)
);

// $FF80800-$FF817FF: colour RAM beyond the C65's 2K (80 column full-colour
// screens).  The video chip sees it at $60000.
dpram #(12, 8) cram2 (
	.clk(clk),
	.a_addr(mem_addr[11:0]), .a_din(bus_dout), .a_we(bus_ce && bus_we && sel_cram2), .a_q(cram2_q),
	.b_addr(vaddr[11:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vcram2_q)
);

always_ff @(posedge clk) vsel <= vaddr[18:17];
assign vram_q = (vsel == 2'd2) ? vram2_q : (vsel == 2'd3) ? vcram2_q : vram1_q;
assign vrom_q = wom_loaded ? vwom_q : vrom1_q;

// use the character set RAM once the ROM has filled it
always_ff @(posedge clk) begin
	if (reset) wom_loaded <= 1'b0;
	else if (bus_ce && bus_we && sel_wom && mem_addr[11:0] == 12'hFFF) wom_loaded <= 1'b1;
end

dpram #(17, 8) ram (
	.clk(clk),
	.a_addr(prg_we ? {1'b0, prg_addr} : ram_addr), .a_din(prg_we ? prg_data : bus_dout),
	.a_we(prg_we || (bus_ce && bus_we && ram_sel)), .a_q(ram_q),
	.b_addr(vaddr[16:0]), .b_din(8'd0), .b_we(1'b0), .b_q(vram1_q)
);

dpram #(17, 8) rom (
	.clk(clk),
	.a_addr(ld_wr ? ld_addr : mem_addr), .a_din(ld_data), .a_we(ld_wr), .a_q(rom_q),
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

always_ff @(posedge clk) begin
	if (reset) for (int i = 0; i < 16; i++) uart_regs[i] <= '0;
	else if (io_wr && io_uart && !m65_reg) uart_regs[io_addr[3:0]] <= bus_dout;
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
	// $D629 is the MEGA65 hardware model: answer as a MEGA65 R3
	if (m65_reg) uart_dout = (io_addr[7:0] == 8'h29) ? 8'h03 : 8'h00;
end

c65_keyboard keyboard (
	.clk(clk), .reset(reset), .layout(kbd_layout), .ps2_key(ps2_key),
	.col_sel(cia1_pa_out), .col8_sel(porte[1]), .row_drive(cia1_pb_out),
	.row_in(kb_rows), .col_in(kb_cols),
	.restore_n(restore_n), .capslock_n(capslock_n)
);

// ------------------------------------------------------------------ F011 floppy controller
logic [7:0] fdc_dout;
logic       fdc_irq_n;

f011 fdc (
	.clk(clk), .reset(reset),
	.reg_addr(io_addr[4:0]), .reg_we(io_wr && io_fdc), .reg_re(io_rd && io_fdc),
	.reg_din(bus_dout), .reg_dout(fdc_dout), .irq_n(fdc_irq_n),
	.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
	.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr), .led(drive_led)
);

// ------------------------------------------------------------------ SIDs
logic [7:0] sid_dout;

`ifdef C65_NO_SID
// simulation stub: only the POT registers ($19 / $1A) answer
assign sid_dout = (io_addr[4:0] == 5'h19) ? pot_x : (io_addr[4:0] == 5'h1A) ? pot_y : 8'h00;
assign audio_l  = '0;
assign audio_r  = '0;
`else
sid_top #(.MULTI_FILTERS(1), .DUAL(1)) sid (
	.reset(reset), .clk(clk), .ce_1m(phi2_n),
	.cs({slow_cs && io_sid && io_addr[5], slow_cs && io_sid && !io_addr[5]}),
	.we(bus_we), .addr(io_addr[4:0]), .data_in(bus_dout), .data_out(sid_dout),
	.fc_offset_l(13'd0), .pot_x_l(pot_x), .pot_y_l(pot_y), .ext_in_l(18'd0), .audio_l(audio_r),
	.fc_offset_r(13'd0), .pot_x_r(pot_x), .pot_y_r(pot_y), .ext_in_r(18'd0), .audio_r(audio_l),
	.filter_en(2'b11), .mode(2'b11), .cfg(4'd0),
	.ld_clk(clk), .ld_addr(12'd0), .ld_data(16'd0), .ld_wr(1'b0)
);
`endif

// ------------------------------------------------------------------ MEGA65 extras
logic [7:0] math_dout, rtc_dout;
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
		$display("VIC4 %s $D0%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_dout, dbg_pc);
	if (bus_ce && io_dma && io_addr[7:0] > 8'h03)
		$display("DMA+ %s $D7%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_dout, dbg_pc);
	if (bus_ce && io_uart && io_addr[7:0] > 8'h0F)
		$display("M65  %s $D6%02x = %02x  PC=%04x", bus_we ? "wr" : "rd", io_addr[7:0], bus_dout, dbg_pc);
	if (bus_ce && cpu_far && !dma_busy && !sel_ram && !sel_ram2 && !sel_cram2 && !sel_wom && !sel_rom && !sel_io && !sel_xram && !sel_rtc)
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
	else if (io_hyp)  io_dout = 8'h00;
	else if (io_rec)  io_dout = (io_addr[7:0] == 8'hA0) ? {!xram_present, rec_reg} : 8'hFF;
	else if (io_cia1) io_dout = cia1_dout;
	else if (io_cia2) io_dout = cia2_dout;
end

always_comb begin
	if (ram_sel)       bus_din = ram_q;
	else if (sel_ram2) bus_din = ram2_q;
	else if (sel_cram2) bus_din = cram2_q;
	else if (sel_wom)  bus_din = wom_q;
	else if (sel_xram) bus_din = xram_dout;
	else if (sel_rtc)  bus_din = rtc_dout;
	else if (sel_rom)  bus_din = rom_q;
	else if (sel_port) bus_din = cpu_addr[0] ? port_val : port_ddr;
	else if (sel_io)   bus_din = io_dout;
	else               bus_din = 8'hFF;
end

// $D705 (enhanced DMA job) only exists in MEGA65 mode
assign dma_reg_we = io_wr && io_dma && (io_addr[7:3] == 5'd0) && (io_addr[2:0] != 3'd5 || gs_mode);
assign dbg_op     = bus_din;

assign irq_n = vic_irq_n & cia1_irq_n & fdc_irq_n & ser_irq_n;
assign nmi_n = cia2_irq_n & restore_n;

endmodule
