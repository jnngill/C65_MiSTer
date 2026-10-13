// CSG F011 floppy disk controller, backed by a .D81 image through the MiSTer
// block interface.  (Work in progress: currently reports "no disk".)

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

logic [7:0] control, track, sector, side, clock, step;
logic       rnf;

assign irq_n = 1'b1;
assign sd_lba = '0;
assign sd_rd = 1'b0;
assign sd_wr = 1'b0;
assign sd_buff_din = 8'h00;
assign led = control[5];

always_ff @(posedge clk) begin
	if (reset) begin
		control <= '0; track <= '0; sector <= '0; side <= '0; clock <= 8'hFF; step <= 8'h80; rnf <= 1'b0;
	end
	else if (reg_we) begin
		case (reg_addr)
			5'd0: control <= reg_din;
			5'd1: rnf <= reg_din[7] | reg_din[6];
			5'd4: track <= reg_din;
			5'd5: sector <= reg_din;
			5'd6: side <= reg_din;
			5'd8: clock <= reg_din;
			5'd9: step <= reg_din;
			default: ;
		endcase
	end
end

always_comb begin
	case (reg_addr)
		5'd0: reg_dout = control;
		5'd1: reg_dout = 8'h00;
		5'd2: reg_dout = {3'b000, rnf, 3'b000, 1'b1};
		5'd3: reg_dout = 8'h00;
		5'd4: reg_dout = track;
		5'd5: reg_dout = sector;
		5'd6: reg_dout = side;
		5'd8: reg_dout = clock;
		5'd9: reg_dout = step;
		default: reg_dout = 8'h00;
	endcase
end

endmodule
