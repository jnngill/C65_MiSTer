// 16K hypervisor RAM ($8000-$BFFF in hypervisor mode), preloaded with the
// hypervisor program built from rtl/hyppo (hyppo.hex, one byte per line).
module hyp_ram (
	input  logic        clk,
	input  logic [13:0] addr,
	input  logic  [7:0] din,
	input  logic        we,
	output logic  [7:0] q
);

logic [7:0] mem [0:16383] /* verilator public_flat_rd */;
initial $readmemh("rtl/hyppo/hyppo.hex", mem);

always_ff @(posedge clk) begin
	if (we) mem[addr] <= din;
	q <= mem[addr];
end

endmodule
