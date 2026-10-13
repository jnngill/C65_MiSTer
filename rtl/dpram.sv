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
