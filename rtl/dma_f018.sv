// CSG F018 "DMAgic" DMA controller (F018A 11-byte and F018B 12-byte lists).
//
// The system core owns the bus cycle: while busy is high the DMA is bus
// master and every ce pulse completes one access (addr/io/we/dout, din).
// COPY, FILL and SWAP are implemented; MIX is treated as COPY and the modulo
// options are ignored (as on real hardware, where they never worked).

module dma_f018 (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,          // bus cycle complete (only counted while busy)
	input  logic        f018b,       // list format: 0 = F018A, 1 = F018B

	input  logic  [1:0] reg_addr,
	input  logic        reg_we,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,

	output logic        busy,
	output logic        setup,       // decoding the list this clk: no bus cycle may start
	output logic [19:0] addr,
	output logic        io,          // addr[11:0] is an I/O ($Dxxx) address
	output logic        we,
	output logic  [7:0] dout,
	input  logic  [7:0] din
);

typedef enum logic [2:0] { IDLE, LIST, SETUP, RD_SRC, RD_DST, WR_DST, WR_SRC } state_t;
state_t state;

logic [15:0] list_addr;
logic  [6:0] list_bank;
logic  [3:0] list_idx;
logic  [7:0] list [12];
logic [19:0] src, dst;
logic        src_io, dst_io, src_hold, dst_hold, src_dec, dst_dec;
logic [16:0] count;
logic  [1:0] op;
logic        chain;
logic  [7:0] sdata, ddata;

wire [3:0] list_last = f018b ? 4'd11 : 4'd10;
wire [7:0] sbank = list[5];
wire [7:0] dbank = list[8];

function automatic [19:0] step(input logic [19:0] a, input logic is_io, input logic hold, input logic dec);
	logic [19:0] n;
	n = hold ? a : (dec ? a - 20'd1 : a + 20'd1);
	step = is_io ? {a[19:12], n[11:0]} : n;
endfunction

assign busy  = (state != IDLE);
assign setup = (state == SETUP);

always_comb begin
	addr = {list_bank[3:0], list_addr};
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
		2'd0: reg_dout = list_addr[7:0];
		2'd1: reg_dout = list_addr[15:8];
		2'd2: reg_dout = {1'b0, list_bank};
		2'd3: reg_dout = {busy, 6'd0, f018b};
	endcase
end

always_ff @(posedge clk) begin
	if (reset) begin
		state <= IDLE;
		list_addr <= '0; list_bank <= '0; list_idx <= '0;
	end
	else begin
		if (reg_we && !busy) begin
			case (reg_addr)
				2'd0: begin list_addr[7:0] <= reg_din; list_idx <= '0; state <= LIST; end
				2'd1: list_addr[15:8] <= reg_din;
				2'd2: list_bank <= reg_din[6:0];
				default: ;
			endcase
		end

		if (ce) begin
			case (state)
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
						if (chain) begin list_idx <= '0; state <= LIST; end
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
					if (chain) begin list_idx <= '0; state <= LIST; end
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
			src    <= {sbank[3:0], list[4], list[3]};
			dst    <= {dbank[3:0], list[7], list[6]};
			src_io <= sbank[7];
			dst_io <= dbank[7];
			if (f018b) begin
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
