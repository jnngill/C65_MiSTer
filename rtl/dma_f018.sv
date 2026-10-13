// CSG F018 "DMAgic" DMA controller (F018A 11-byte and F018B 12-byte lists).
//
// The system core owns the bus cycle: while busy is high the DMA is bus
// master and every ce pulse completes one access (addr/io/we/dout, din).
// COPY, FILL and SWAP are implemented; MIX is treated as COPY and the modulo
// options are ignored (as on real hardware, where they never worked).
//
// Writing the list address to $D705 instead of $D700 starts a MEGA65
// "enhanced" job: the list begins with option bytes, ended by $00.  Options
// with bit 7 set carry one argument byte.  Understood: $80 / $81 source /
// destination megabyte, $0A / $0B list format F018A / F018B; others are
// skipped.

module dma_f018 (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,          // bus cycle complete (only counted while busy)
	input  logic        f018b,       // list format: 0 = F018A, 1 = F018B

	input  logic  [2:0] reg_addr,
	input  logic        reg_we,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,

	output logic        busy,
	output logic        setup,       // decoding the list this clk: no bus cycle may start
	output logic [27:0] addr,        // flat address: megabyte (enhanced jobs), bank, 16-bit address
	output logic        io,          // I/O flag of the bank byte: $D000-$DFFF means I/O, not RAM
	output logic        we,
	output logic  [7:0] dout,
	input  logic  [7:0] din
);

typedef enum logic [2:0] { IDLE, OPT, LIST, SETUP, RD_SRC, RD_DST, WR_DST, WR_SRC } state_t;
state_t state;

logic [15:0] list_addr;
logic  [6:0] list_bank;
logic  [3:0] list_idx;
logic  [7:0] list [12];
logic [27:0] src, dst;
logic        enh;            // enhanced job (started through $D705)
logic        job_b;          // list format of this job: 1 = F018B
logic        opt_arg;        // next list byte is the argument of opt_code
logic  [7:0] opt_code, src_mb, dst_mb;
logic        src_io, dst_io, src_hold, dst_hold, src_dec, dst_dec;
logic [16:0] count;
logic  [1:0] op;
logic        chain;
logic  [7:0] sdata, ddata;

wire [3:0] list_last = job_b ? 4'd11 : 4'd10;
wire [7:0] sbank = list[5];
wire [7:0] dbank = list[8];

function automatic [27:0] step(input logic [27:0] a, input logic is_io, input logic hold, input logic dec);
	step = hold ? a : (dec ? a - 28'd1 : a + 28'd1);
endfunction

assign busy  = (state != IDLE);
assign setup = (state == SETUP);

always_comb begin
	addr = {5'd0, list_bank, list_addr};
	io   = 1'b0;
	we   = 1'b0;
	dout = sdata;
	case (state)
		RD_SRC: begin addr = src; io = src_io; end
		RD_DST: begin addr = dst; io = dst_io; end
		WR_DST: begin addr = dst; io = dst_io; we = 1'b1; dout = (op == 2'd3) ? src[7:0] : sdata; end
		WR_SRC: begin addr = src; io = src_io; we = 1'b1; dout = ddata; end
		default: ;
	endcase
end

always_comb begin
	case (reg_addr)
		3'd0, 3'd5: reg_dout = list_addr[7:0];
		3'd1: reg_dout = list_addr[15:8];
		3'd2: reg_dout = {1'b0, list_bank};
		3'd3: reg_dout = {busy, 6'd0, f018b};
		default: reg_dout = 8'h00;
	endcase
end

always_ff @(posedge clk) begin
	if (reset) begin
		state <= IDLE;
		list_addr <= '0; list_bank <= '0; list_idx <= '0;
		enh <= 1'b0; job_b <= 1'b1; opt_arg <= 1'b0; src_mb <= '0; dst_mb <= '0;
	end
	else begin
		if (reg_we && !busy) begin
			case (reg_addr)
				3'd0: begin list_addr[7:0] <= reg_din; list_idx <= '0; enh <= 1'b0; job_b <= f018b; state <= LIST; end
				3'd1: list_addr[15:8] <= reg_din;
				3'd2: list_bank <= reg_din[6:0];
				3'd5: begin
					list_addr[7:0] <= reg_din; list_idx <= '0; enh <= 1'b1; job_b <= f018b;
					opt_arg <= 1'b0; src_mb <= '0; dst_mb <= '0; state <= OPT;
				end
				default: ;
			endcase
		end

		if (ce) begin
			case (state)
			OPT: begin
				list_addr <= list_addr + 16'd1;
				if (opt_arg) begin
					opt_arg <= 1'b0;
					if (opt_code == 8'h80) src_mb <= din;
					if (opt_code == 8'h81) dst_mb <= din;
				end
				else if (din == 8'h00) begin list_idx <= '0; state <= LIST; end
				else if (din[7]) begin opt_code <= din; opt_arg <= 1'b1; end
				else begin
					if (din == 8'h0A) job_b <= 1'b0;
					if (din == 8'h0B) job_b <= 1'b1;
				end
			end

			LIST: begin
				list[list_idx] <= din;
				list_addr <= list_addr + 16'd1;
				if (list_idx == list_last) state <= SETUP;
				else list_idx <= list_idx + 4'd1;
			end

			RD_SRC: begin sdata <= din; state <= (op == 2'd2) ? RD_DST : WR_DST; end
			RD_DST: begin ddata <= din; state <= WR_DST; end
			WR_DST: begin
				if (op == 2'd2) state <= WR_SRC;
				else begin
					src <= step(src, src_io, src_hold || (op == 2'd3), src_dec);
					dst <= step(dst, dst_io, dst_hold, dst_dec);
					count <= count - 17'd1;
					if (count == 17'd1) begin
						if (chain) begin list_idx <= '0; opt_arg <= 1'b0; state <= enh ? OPT : LIST; end
						else state <= IDLE;
					end
					else state <= (op == 2'd3) ? WR_DST : RD_SRC;
				end
			end
			WR_SRC: begin
				src <= step(src, src_io, src_hold, src_dec);
				dst <= step(dst, dst_io, dst_hold, dst_dec);
				count <= count - 17'd1;
				if (count == 17'd1) begin
					if (chain) begin list_idx <= '0; opt_arg <= 1'b0; state <= enh ? OPT : LIST; end
					else state <= IDLE;
				end
				else state <= RD_SRC;
			end
			default: ;
			endcase
		end

		// list fully read: decode it (no bus access in this state)
		if (state == SETUP) begin
			op     <= list[0][1:0];
			chain  <= list[0][2];
			count  <= {(list[2] == 8'd0 && list[1] == 8'd0), list[2], list[1]};
			src    <= {src_mb, 20'd0} | {5'd0, job_b ? sbank[6:4] : 3'd0, sbank[3:0], list[4], list[3]};
			dst    <= {dst_mb, 20'd0} | {5'd0, job_b ? dbank[6:4] : 3'd0, dbank[3:0], list[7], list[6]};
			src_io <= sbank[7];
			dst_io <= dbank[7];
			if (job_b) begin
				src_dec  <= list[0][4];
				dst_dec  <= list[0][5];
				src_hold <= list[9][1];
				dst_hold <= list[9][3];
			end else begin
				src_dec  <= sbank[6];
				dst_dec  <= dbank[6];
				src_hold <= sbank[4];
				dst_hold <= dbank[4];
			end
			state <= (list[0][1:0] == 2'd3) ? WR_DST : RD_SRC;
		end
	end
end

endmodule
