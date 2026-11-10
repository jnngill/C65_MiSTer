// Generic true dual-port RAM with registered outputs (infers M10K blocks).
module dpram #(
	parameter int AW = 17,
	parameter int DW = 8
)(
	input  logic          clk,
	input  logic [AW-1:0] a_addr,
	input  logic [DW-1:0] a_din,
	input  logic          a_we,
	output logic [DW-1:0] a_q,
	input  logic [AW-1:0] b_addr,
	input  logic [DW-1:0] b_din,
	input  logic          b_we,
	output logic [DW-1:0] b_q
);

(* ramstyle = "no_rw_check" *) logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rd */;

always_ff @(posedge clk) begin
	if (a_we) mem[a_addr] <= a_din;
	a_q <= mem[a_addr];
end

always_ff @(posedge clk) begin
	if (b_we) mem[b_addr] <= b_din;
	b_q <= mem[b_addr];
end

endmodule

// dpram with the write's block select taken from a_wsel, the address the
// write really goes to (it must equal a_addr whenever a_we is set).  a_addr
// may carry a late, speculated read address; Quartus would otherwise decode
// the M10K write enables from it, putting that path in front of every write.
// Synthesis builds it from 8K-deep banks; simulation keeps one flat array.
module dpram_ws #(
	parameter int AW = 17,
	parameter int DW = 8
)(
	input  logic          clk,
	input  logic [AW-1:0] a_addr,
	input  logic [AW-1:0] a_wsel,
	input  logic [DW-1:0] a_din,
	input  logic          a_we,
	output logic [DW-1:0] a_q,
	input  logic [AW-1:0] b_addr,
	output logic [DW-1:0] b_q
);

`ifdef VERILATOR
logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rd */;

always_ff @(posedge clk) begin
	if (a_we) begin
		mem[a_addr] <= a_din;
		if (a_wsel != a_addr) $error("dpram_ws: write select %h != address %h", a_wsel, a_addr);
	end
	a_q <= mem[a_addr];
	b_q <= mem[b_addr];
end
`else
localparam int BW = 13;                 // M10K: 8K x 1
localparam int NB = 1 << (AW - BW);

logic [AW-BW-1:0] a_bank, b_bank;
logic [DW-1:0]    a_qs [NB], b_qs [NB];

always_ff @(posedge clk) begin
	a_bank <= a_addr[AW-1:BW];
	b_bank <= b_addr[AW-1:BW];
end

genvar i;
generate
	for (i = 0; i < NB; i++) begin : bank
		dpram #(BW, DW) m (
			.clk(clk),
			.a_addr(a_addr[BW-1:0]), .a_din(a_din), .a_we(a_we && a_wsel[AW-1:BW] == i), .a_q(a_qs[i]),
			.b_addr(b_addr[BW-1:0]), .b_din('0), .b_we(1'b0), .b_q(b_qs[i])
		);
	end
endgenerate

assign a_q = a_qs[a_bank];
assign b_q = b_qs[b_bank];
`endif

endmodule
