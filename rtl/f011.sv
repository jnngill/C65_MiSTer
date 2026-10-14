// CSG F011 floppy disk controller for the C65's internal 3.5" drive, backed
// by a .D81 image through the MiSTer block interface (512 byte blocks, which
// are exactly the physical sectors of a 1581 disk).
//
// Sector level emulation, buffered mode only (which is what the C65 DOS
// uses): a read command fills the 512 byte sector buffer and the CPU then
// drains it through $D087; a write command stores the buffer.  A write
// track command ($A0/$A1, used by HEADER to format) fills the 10 sectors of
// the track under the head, on the side picked by control bit 3, with zeros.
//
//   block = track * 20 + (sector - 1) + (side ? 10 : 0)

module f011 (
	input  logic        clk,
	input  logic        reset,

	input  logic  [4:0] reg_addr,
	input  logic        reg_we,
	input  logic        reg_re,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,
	output logic        irq_n,

	input  logic        img_mounted,
	input  logic        img_readonly,
	input  logic [31:0] img_size,
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	output logic        sd_wr,
	input  logic        sd_ack,
	input  logic  [8:0] sd_buff_addr,
	input  logic  [7:0] sd_buff_dout,
	output logic  [7:0] sd_buff_din,
	input  logic        sd_buff_wr,
	output logic        led
);

// ------------------------------------------------------------------ registers
logic [7:0] control, command, track, sector, side, clock, step;
logic       busy, rnf, crc, lost, eq, rdreq, wtreq, irq_flag, dskchg;
logic       present = 1'b0, readonly = 1'b0;
logic [6:0] head;
logic [8:0] cpu_ptr, base_ptr;
logic [24:0] index_cnt;
logic [15:0] delay;

wire       drive0  = (control[2:0] == 3'd0);
wire       swap    = control[4];
wire       motor   = control[5];
wire       disk_ok = present && drive0;
wire       index   = motor && disk_ok && (index_cnt[24:19] == 6'd0);

// an absent drive (select 1-7) never leaves "track 0": that is how the ROM detects it
wire [7:0] stat_a = {busy, !eq && rdreq, eq, rnf, crc, lost, disk_ok && readonly, !drive0 || head == 7'd0};
wire [7:0] stat_b = {rdreq, wtreq, rdreq, 1'b0, disk_ok, index, irq_flag, dskchg || !disk_ok};

assign led   = motor;
assign irq_n = 1'b1;

// ------------------------------------------------------------------ sector buffer
logic [7:0] buf_q, buf_disk_q;
wire        data_wr = reg_we && reg_addr == 5'd7;
wire        data_rd = reg_re && reg_addr == 5'd7;

assign sd_buff_din = (state == ST_FMT) ? 8'h00 : buf_disk_q;

// ------------------------------------------------------------------ command execution
typedef enum logic [2:0] { ST_IDLE, ST_DELAY, ST_READ, ST_WRITE, ST_FAIL, ST_FMT } state_t;
state_t state;
logic   ack_seen;
logic [3:0] fmt_n;

dpram #(9, 8) sector_buf (
	.clk(clk),
	.a_addr({cpu_ptr[8] ^ swap, cpu_ptr[7:0]}), .a_din(reg_din), .a_we(data_wr), .a_q(buf_q),
	.b_addr(base_ptr + sd_buff_addr), .b_din(sd_buff_dout), .b_we(sd_buff_wr && sd_ack && state == ST_READ),
	.b_q(buf_disk_q)
);

wire [10:0] block     = {4'd0, track[6:0]} * 11'd20 + {7'd0, sector[3:0]} - 11'd1 + (side[0] ? 11'd10 : 11'd0);
wire        chs_valid = (track < 8'd80) && (sector >= 8'd1) && (sector <= 8'd10) && (side < 8'd2);
// write track: control bit 3 set selects side 0
wire [10:0] fmt_block = {4'd0, head} * 11'd20 + {7'd0, fmt_n} + (control[3] ? 11'd0 : 11'd10);

always_ff @(posedge clk) begin
	index_cnt <= index_cnt + 25'd1;
	if (index_cnt == 25'd6299999) index_cnt <= '0;          // ~200 ms per revolution

	if (img_mounted) begin
		present  <= (img_size != 32'd0);
		readonly <= img_readonly;
		dskchg   <= 1'b1;
	end

	if (reset) begin
		control <= '0; command <= '0; track <= '0; sector <= '0; side <= '0; clock <= 8'hFF; step <= 8'h80;
		busy <= 1'b0; rnf <= 1'b0; crc <= 1'b0; lost <= 1'b0; eq <= 1'b1; rdreq <= 1'b0; wtreq <= 1'b0;
		irq_flag <= 1'b0; dskchg <= 1'b1; head <= 7'd0; cpu_ptr <= '0; base_ptr <= '0;
		state <= ST_IDLE; sd_rd <= 1'b0; sd_wr <= 1'b0; ack_seen <= 1'b0; delay <= '0;
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
						if (!reg_din[2] && drive0) begin
							if (reg_din[3]) begin if (head != 7'd81) head <= head + 7'd1; end
							else            begin if (head != 7'd0)  head <= head - 7'd1; end
						end
						if (disk_ok) dskchg <= 1'b0;
						busy <= 1'b1; delay <= 16'd2000; state <= ST_DELAY;
					end
					else if (reg_din[7:5] == 3'b101) begin
						// write track
						busy <= 1'b1; fmt_n <= '0;
						if (disk_ok && head < 7'd80 && !readonly) begin
							sd_lba <= {21'd0, {4'd0, head} * 11'd20 + (control[3] ? 11'd0 : 11'd10)}; sd_wr <= 1'b1; ack_seen <= 1'b0; state <= ST_FMT;
						end
						else begin delay <= 16'd2000; state <= ST_FAIL; end
					end
					else if (reg_din[7]) begin
						busy <= 1'b1;
						if (disk_ok && chs_valid && !readonly) begin
							sd_lba <= {21'd0, block}; sd_wr <= 1'b1; ack_seen <= 1'b0; state <= ST_WRITE;
							base_ptr <= reg_din[0] ? 9'd0 : cpu_ptr;
						end
						else begin delay <= 16'd2000; state <= ST_FAIL; end
					end
					else if (reg_din[6]) begin
						busy <= 1'b1;
						if (disk_ok && chs_valid) begin
							sd_lba <= {21'd0, block}; sd_rd <= 1'b1; ack_seen <= 1'b0; state <= ST_READ;
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
						busy <= 1'b0; state <= ST_IDLE; sd_rd <= 1'b0; sd_wr <= 1'b0;
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
				if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; ack_seen <= 1'b1; end
				else if (ack_seen) begin
					busy <= 1'b0; irq_flag <= 1'b1;
					if (state == ST_READ) begin rdreq <= 1'b1; eq <= 1'b0; end
					else wtreq <= 1'b1;
					state <= ST_IDLE;
				end
			end
			ST_FMT: begin
				if (sd_ack) begin sd_wr <= 1'b0; ack_seen <= 1'b1; end
				else if (ack_seen) begin
					ack_seen <= 1'b0;
					if (fmt_n == 4'd9) begin busy <= 1'b0; irq_flag <= 1'b1; state <= ST_IDLE; end
					else begin
						fmt_n  <= fmt_n + 4'd1;
						sd_lba <= {21'd0, fmt_block + 11'd1};
						sd_wr  <= 1'b1;
					end
				end
			end
			default: ;
		endcase
	end
end

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
