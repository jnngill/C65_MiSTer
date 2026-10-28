// CSG F011 floppy disk controller for the C65's internal 3.5" drive, backed
// by a .D81 image through the MiSTer block interface.  Each physical 1581
// sector (512 bytes) is fetched as two 256 byte blocks: sd_lba counts 256 byte
// blocks and the top level asks for a block count of 2.
//
// Sector level emulation, buffered mode only (which is what the C65 DOS
// uses): a read command fills the 512 byte sector buffer and the CPU then
// drains it through $D087; a write command stores the buffer.  A write
// track command ($A0/$A1, used by HEADER to format) fills the 10 sectors of
// the track under the head, on the side picked by control bit 3, with zeros.
//
//   block = track * 20 + (sector - 1) + (side ? 10 : 0)
//
// Drive select 0 (control bits 2-0) is the internal drive, drive select 1 an
// external 1565 on the C65's drive port, each with its own image and head.
// Drive 1 only exists while an image is mounted for it; an absent drive
// (and selects 2-7) never leaves "track 0", which is how the ROM tells.
//
// The MEGA65 also maps the sector buffer flat at $FFD6C00-$FFD6DFF (the dir_*
// port); the BASIC 65 DOS reads and writes sectors there instead of $D087.
//
// When the MEGA65 hypervisor attaches a .D81 from the SD card ($D68B bit 0 /
// bit 3: img0_sd / img1_sd), that drive uses the image instead: its sectors
// are read and written through the SD card slot (sd3_*), starting at SD
// sector img0_start / img1_start.  Such an image can also be a D64 / D71
// ($D68A bit 6 / 7: img*_d64) or a D65 ($D68B bit 6 / 7: img*_d65; both set
// is a D71).  As on the MEGA65 the controller keeps the 1581 numbering and
// only limits it to the image's size; the ROM's DOS does the 1541 / 1571
// layout.  A D65 has 64 sectors per track:
//
//   block = track * 128 + (sector - 1) + (side ? 10 : 0)

module f011 (
	input  logic        clk,
	input  logic        reset,

	input  logic  [4:0] reg_addr,
	input  logic        reg_we,
	input  logic        reg_re,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,
	output logic        irq_n,

	// MEGA65 flat window onto the sector buffer ($FFD6C00-$FFD6DFF)
	input  logic        dir_sel,
	input  logic  [8:0] dir_addr,
	input  logic        dir_we,
	output logic  [7:0] dir_q,

	input  logic  [1:0] img_mounted,     // one bit per drive
	input  logic        img_readonly,
	input  logic [31:0] img_size,
	output logic [31:0] sd_lba,
	output logic  [1:0] sd_rd,
	output logic  [1:0] sd_wr,
	input  logic  [1:0] sd_ack,

	input  logic        img0_sd,         // drive 0 is a .D81 on the SD card ...
	input  logic        img0_ok,         // ... media present
	input  logic        img0_wen,        // ... write enabled
	input  logic [31:0] img0_start,      // ... first 512 byte sector of the image
	input  logic        img1_sd,         // the same for drive 1
	input  logic        img1_ok,
	input  logic        img1_wen,
	input  logic [31:0] img1_start,
	input  logic        img0_d64, img0_d65,   // image types (both clear: D81)
	input  logic        img1_d64, img1_d65,
	output logic [31:0] sd3_lba,
	output logic        sd3_rd,
	output logic        sd3_wr,
	input  logic        sd3_ack,
	input  logic  [8:0] sd_buff_addr,
	input  logic  [7:0] sd_buff_dout,
	output logic  [7:0] sd_buff_din,
	input  logic        sd_buff_wr,
	output logic        led
);

// ------------------------------------------------------------------ registers
logic [7:0] control, command, track, sector, side, clock, step;
logic       busy, rnf, crc, lost, eq, rdreq, wtreq, irq_flag;
logic [1:0] dskchg;
logic [1:0] present = 2'b00, readonly = 2'b00;
logic [6:0] heads [2];
logic       xdrv;              // drive of the transfer in progress
logic [1:0] xport;             // its block port: 0 / 1 the drive's own slot, 2 / 3 the SD card (drive 0 / 1)
logic [3:0] rq_rd, rq_wr;      // block requests per port
logic       img0_sd_d, img1_sd_d;
logic [8:0] cpu_ptr, base_ptr;
logic [24:0] index_cnt;
logic [15:0] delay;

wire       drv     = control[0];
wire       exists  = (control[2:0] == 3'd0) || (control[2:0] == 3'd1 && (present[1] || img1_sd));
wire [6:0] head    = heads[drv];
wire       swap    = control[4];
wire       motor   = control[5];
wire [1:0] port    = (drv == 1'b0 && img0_sd) ? 2'd2 : (drv == 1'b1 && img1_sd) ? 2'd3 : {1'b0, drv};
wire       disk_ok = exists && ((port == 2'd2) ? img0_ok : (port == 2'd3) ? img1_ok : present[drv]);
wire       ro      = (port == 2'd2) ? !img0_wen : (port == 2'd3) ? !img1_wen : readonly[drv];
wire       ack     = |sd_ack || sd3_ack;

assign sd_rd   = rq_rd[1:0];
assign sd_wr   = rq_wr[1:0];
assign sd3_rd  = rq_rd[2] | rq_rd[3];
assign sd3_wr  = rq_wr[2] | rq_wr[3];
assign sd3_lba = {(xport == 2'd3 ? img1_start[30:0] : img0_start[30:0]), 1'b0} + sd_lba;
wire       index   = motor && disk_ok && (index_cnt[24:19] == 6'd0);

wire [7:0] stat_a = {busy, !eq && rdreq, eq, rnf, crc, lost, disk_ok && ro, !exists || head == 7'd0};
wire [7:0] stat_b = {rdreq, wtreq, rdreq, 1'b0, disk_ok, index, irq_flag, dskchg[drv] || !disk_ok};

assign led   = motor;
assign irq_n = 1'b1;

// ------------------------------------------------------------------ sector buffer
logic [7:0] buf_q, buf_disk_q;
wire        data_wr = reg_we && reg_addr == 5'd7;
wire        data_rd = reg_re && reg_addr == 5'd7;

assign sd_buff_din = (state == ST_FMT) ? 8'h00 : buf_disk_q;
assign dir_q       = buf_q;

// ------------------------------------------------------------------ command execution
typedef enum logic [2:0] { ST_IDLE, ST_DELAY, ST_READ, ST_WRITE, ST_FAIL, ST_FMT } state_t;
state_t state;
logic   ack_seen;
logic [3:0] fmt_n;

dpram #(9, 8) sector_buf (
	.clk(clk),
	.a_addr(dir_sel ? dir_addr : {cpu_ptr[8] ^ swap, cpu_ptr[7:0]}), .a_din(reg_din), .a_we(data_wr || dir_we), .a_q(buf_q),
	.b_addr(base_ptr + sd_buff_addr), .b_din(sd_buff_dout), .b_we(sd_buff_wr && ack && state == ST_READ),
	.b_q(buf_disk_q)
);

// image type of the selected drive (drives without an SD card image are D81)
wire        t_d64     = (port == 2'd2) ? img0_d64 : (port == 2'd3) ? img1_d64 : 1'b0;
wire        t_d65     = (port == 2'd2) ? img0_d65 : (port == 2'd3) ? img1_d65 : 1'b0;
wire  [6:0] p_sec     = 7'({1'b0, sector[5:0]} - 7'd1 + (side[0] ? 7'd10 : 7'd0));
wire [13:0] block     = (t_d65 && !t_d64) ? {track[6:0], 7'd0} + {7'd0, p_sec}
                                          : 14'({7'd0, track[6:0]} * 14'd20 + {7'd0, p_sec});
wire        chs_d81   = (track < 8'd80) && (sector >= 8'd1) && (sector <= 8'd10) && (side < 8'd2);
wire        chs_valid = (t_d65 && !t_d64) ? (track < 8'd85) && (sector >= 8'd1) && (p_sec < 7'd64) && (side < 8'd2)
                      : t_d64 ? chs_d81 && (block < (t_d65 ? 14'd683 : 14'd342))
                      : chs_d81;
// write track: control bit 3 set selects side 0
wire [10:0] fmt_block = {4'd0, head} * 11'd20 + {7'd0, fmt_n} + (control[3] ? 11'd0 : 11'd10);

always_ff @(posedge clk) begin
	index_cnt <= index_cnt + 25'd1;
	if (index_cnt == 25'd6299999) index_cnt <= '0;          // ~200 ms per revolution

	// attaching or detaching an SD card image changes drive 0's disk
	img0_sd_d <= img0_sd;
	img1_sd_d <= img1_sd;
	if (img0_sd != img0_sd_d) dskchg[0] <= 1'b1;
	if (img1_sd != img1_sd_d) dskchg[1] <= 1'b1;

	for (int d = 0; d < 2; d++) begin
		if (img_mounted[d]) begin
			present[d]  <= (img_size != 32'd0);
			readonly[d] <= img_readonly;
			dskchg[d]   <= 1'b1;
		end
	end

	if (reset) begin
		control <= '0; command <= '0; track <= '0; sector <= '0; side <= '0; clock <= 8'hFF; step <= 8'h80;
		busy <= 1'b0; rnf <= 1'b0; crc <= 1'b0; lost <= 1'b0; eq <= 1'b1; rdreq <= 1'b0; wtreq <= 1'b0;
		irq_flag <= 1'b0; dskchg <= 2'b11; heads[0] <= 7'd0; heads[1] <= 7'd0; cpu_ptr <= '0; base_ptr <= '0;
		state <= ST_IDLE; rq_rd <= '0; rq_wr <= '0; ack_seen <= 1'b0; delay <= '0; xdrv <= 1'b0; xport <= '0;
	end
	else begin
		// CPU side of the sector buffer
		if (data_wr || data_rd) begin
			cpu_ptr <= cpu_ptr + 9'd1;
			eq      <= (cpu_ptr + 9'd1 == base_ptr);
			if (cpu_ptr + 9'd1 == base_ptr) rdreq <= 1'b0;
		end

		if (reg_we) begin
			case (reg_addr)
				5'd0: begin
					control <= reg_din;
					if (!reg_din[7]) irq_flag <= 1'b0;
				end
				5'd1: begin
					// new command
					command <= reg_din;
`ifdef F011_DEBUG
					$display("F011 cmd %02x trk %0d sec %0d side %0d head %0d ptr %0d ctl %02x", reg_din, track, sector, side, head, cpu_ptr, control);
`endif
					rnf <= 1'b0; crc <= 1'b0; lost <= 1'b0; wtreq <= 1'b0; irq_flag <= 1'b0;
					if (reg_din[0]) begin cpu_ptr <= '0; base_ptr <= '0; eq <= 1'b1; rdreq <= 1'b0; end
					if (reg_din[7:5] == 3'b000 && reg_din[4]) begin
						// head step: $10 out, $14 settle only, $18 in
						if (!reg_din[2] && exists) begin
							if (reg_din[3]) begin if (head != 7'd81) heads[drv] <= head + 7'd1; end
							else            begin if (head != 7'd0)  heads[drv] <= head - 7'd1; end
						end
						if (disk_ok) dskchg[drv] <= 1'b0;
						busy <= 1'b1; delay <= 16'd2000; state <= ST_DELAY;
					end
					else if (reg_din[7:5] == 3'b101) begin
						// write track
						busy <= 1'b1; fmt_n <= '0;
						if (disk_ok && head < 7'd80 && !ro) begin
							sd_lba <= {20'd0, {4'd0, head} * 11'd20 + (control[3] ? 11'd0 : 11'd10), 1'b0}; rq_wr[port] <= 1'b1; xdrv <= drv; xport <= port; ack_seen <= 1'b0; state <= ST_FMT;
						end
						else begin delay <= 16'd2000; state <= ST_FAIL; end
					end
					else if (reg_din[7]) begin
						busy <= 1'b1;
						if (disk_ok && chs_valid && !ro) begin
							sd_lba <= {17'd0, block, 1'b0}; rq_wr[port] <= 1'b1; xdrv <= drv; xport <= port; ack_seen <= 1'b0; state <= ST_WRITE;
							base_ptr <= reg_din[0] ? 9'd0 : cpu_ptr;
						end
						else begin delay <= 16'd2000; state <= ST_FAIL; end
					end
					else if (reg_din[6]) begin
						busy <= 1'b1;
						if (disk_ok && chs_valid) begin
							sd_lba <= {17'd0, block, 1'b0}; rq_rd[port] <= 1'b1; xdrv <= drv; xport <= port; ack_seen <= 1'b0; state <= ST_READ;
							base_ptr <= reg_din[0] ? 9'd0 : cpu_ptr;
						end
						else begin delay <= 16'd2000; state <= ST_FAIL; end
					end
					else if (reg_din[5]) begin
						// spin up
						busy <= 1'b1; delay <= 16'd2000; state <= ST_DELAY;
					end
					else if (reg_din[7:1] == 7'd0) begin
						// cancel / reset pointers
						busy <= 1'b0; state <= ST_IDLE; rq_rd <= '0; rq_wr <= '0;
					end
				end
				5'd4: track  <= reg_din;
				5'd5: sector <= reg_din;
				5'd6: side   <= reg_din;
				5'd8: clock  <= reg_din;
				5'd9: step   <= reg_din;
				default: ;
			endcase
		end

		case (state)
			ST_DELAY, ST_FAIL: begin
				if (delay != 16'd0) delay <= delay - 16'd1;
				else begin
					busy <= 1'b0; irq_flag <= 1'b1;
					if (state == ST_FAIL) rnf <= 1'b1;
					state <= ST_IDLE;
				end
			end
			ST_READ, ST_WRITE: begin
				if (ack) begin rq_rd <= '0; rq_wr <= '0; ack_seen <= 1'b1; end
				else if (ack_seen) begin
					busy <= 1'b0; irq_flag <= 1'b1;
					if (state == ST_READ) begin rdreq <= 1'b1; eq <= 1'b0; end
					else wtreq <= 1'b1;
					state <= ST_IDLE;
				end
			end
			ST_FMT: begin
				if (ack) begin rq_wr <= '0; ack_seen <= 1'b1; end
				else if (ack_seen) begin
					ack_seen <= 1'b0;
					if (fmt_n == 4'd9) begin busy <= 1'b0; irq_flag <= 1'b1; state <= ST_IDLE; end
					else begin
						fmt_n  <= fmt_n + 4'd1;
						sd_lba <= {20'd0, fmt_block + 11'd1, 1'b0};
						rq_wr[xport] <= 1'b1;
					end
				end
			end
			default: ;
		endcase
	end
end

`ifdef F011_DEBUG
logic [7:0] dbg_last_a, dbg_last_b;
always_ff @(posedge clk) begin
	if (reg_re && control[2:0] == 3'd1 && reg_addr == 5'd2 && stat_a != dbg_last_a) begin
		$display("F011 drv1 stat_a %02x", stat_a); dbg_last_a <= stat_a;
	end
	if (reg_re && control[2:0] == 3'd1 && reg_addr == 5'd3 && stat_b != dbg_last_b) begin
		$display("F011 drv1 stat_b %02x", stat_b); dbg_last_b <= stat_b;
	end
end
`endif

always_comb begin
	case (reg_addr)
		5'd0: reg_dout = control;
		5'd1: reg_dout = command;
		5'd2: reg_dout = stat_a;
		5'd3: reg_dout = stat_b;
		5'd4: reg_dout = track;
		5'd5: reg_dout = sector;
		5'd6: reg_dout = side;
		5'd7: reg_dout = buf_q;
		5'd8: reg_dout = clock;
		5'd9: reg_dout = step;
		default: reg_dout = 8'h00;
	endcase
end

endmodule
