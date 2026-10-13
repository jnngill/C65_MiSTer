// MEGA65 hardware multiplier / divider ($D70F, $D768-$D77F).
//
//   $D770-$D773  MULTINA (32 bit)
//   $D774-$D777  MULTINB (32 bit)
//   $D778-$D77F  MULTOUT = MULTINA * MULTINB (64 bit)
//   $D768-$D76F  DIVOUT  = (MULTINA << 32) / MULTINB: fraction in the low
//                32 bits, whole part in the high 32 bits
//   $D70F        bit 7 = divider busy, bit 6 = multiplier busy
//
// MEGA65 ROMs use it for BASIC arithmetic.

module m65_math (
	input  logic       clk,
	input  logic       reset,
	input  logic [7:0] reg_addr,     // low byte of $D7xx
	input  logic       reg_we,
	input  logic [7:0] reg_din,
	output logic [7:0] reg_dout
);

logic [31:0] ina, inb;
logic [63:0] mulout, divout;

// 64 / 32 restoring divider, two quotient bits per clock (32 clocks)
logic [63:0] quo;
logic [32:0] rem;
logic  [5:0] cnt;
logic        div_busy;

logic [32:0] r1, r2;
logic        q1, q2;
logic [63:0] dividend_sh;
always_comb begin
	// first bit
	r1 = {rem[31:0], quo[63]};
	q1 = (r1 >= {1'b0, inb});
	if (q1) r1 = r1 - {1'b0, inb};
	// second bit
	r2 = {r1[31:0], quo[62]};
	q2 = (r2 >= {1'b0, inb});
	if (q2) r2 = r2 - {1'b0, inb};
	dividend_sh = {quo[61:0], q1, q2};
end

always_ff @(posedge clk) begin
	mulout <= ina * inb;

	if (reset) begin
		ina <= '0; inb <= '0; div_busy <= 1'b0; divout <= '0; cnt <= '0; quo <= '0; rem <= '0;
	end
	else begin
		if (div_busy) begin
			quo <= dividend_sh;
			rem <= r2;
			cnt <= cnt + 6'd1;
			if (cnt == 6'd31) begin
				div_busy <= 1'b0;
				divout   <= (inb == 32'd0) ? 64'hFFFFFFFF_FFFFFFFF : dividend_sh;
			end
		end

		if (reg_we && reg_addr[7:3] == 5'b01110) begin      // $70-$77
			case (reg_addr[2:0])
				3'd0: ina[7:0]   <= reg_din;
				3'd1: ina[15:8]  <= reg_din;
				3'd2: ina[23:16] <= reg_din;
				3'd3: ina[31:24] <= reg_din;
				3'd4: inb[7:0]   <= reg_din;
				3'd5: inb[15:8]  <= reg_din;
				3'd6: inb[23:16] <= reg_din;
				3'd7: inb[31:24] <= reg_din;
			endcase
			div_busy <= 1'b1;      // (re)start with the new operands next clock
			cnt      <= 6'd63;
		end
		else if (div_busy && cnt == 6'd63) begin
			quo <= {ina, 32'd0};
			rem <= '0;
			cnt <= '0;
		end
	end
end

always_comb begin
	reg_dout = 8'h00;
	casez (reg_addr)
		8'h0F:       reg_dout = {div_busy, 7'd0};
		8'b0110_1???: reg_dout = divout[reg_addr[2:0]*8 +: 8];
		8'b0111_0???: reg_dout = reg_addr[2] ? inb[reg_addr[1:0]*8 +: 8] : ina[reg_addr[1:0]*8 +: 8];
		8'b0111_1???: reg_dout = mulout[reg_addr[2:0]*8 +: 8];
		default: ;
	endcase
end

endmodule
