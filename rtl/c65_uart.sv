// C65 serial port (UART at $D600-$D606), as the 911210 KERNAL uses it for
// RS-232 (device 2):
//
//   $D600  data: read = received byte, write = byte to send (ignored while
//          sending is disabled)
//   $D601  status: [0] byte received, [1] overrun, [2] parity error,
//          [3] framing error, [6] ready to send, [7] sender idle.
//          Reading $D600 clears [3:0]; any write to $D601 clears them too.
//   $D602  format: [7] send enable, [6] receive enable,
//          [3:2] data bits 8 - n (as in the C64 RS-232 control byte),
//          [1] parity on, [0] parity odd
//   $D603  baud divisor low, $D604 high: baud = 7.09 MHz / (16 * (divisor + 1))
//          (7.16 MHz in NTSC, like the C65's 2x dot clock reference)
//   $D605  interrupt enable: [6] byte received, [7] ready to send
//   $D606  interrupt flags (read only): same bits
//
// One stop bit is sent; anything after the first stop bit is accepted.

module c65_uart (
	input  logic        clk,
	input  logic        reset,
	input  logic        ntsc,

	input  logic  [2:0] reg_addr,
	input  logic        reg_we,
	input  logic        reg_re,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,
	output logic        irq_n,

	input  logic        rxd,
	output logic        txd
);

logic  [7:0] fmt, imask;
logic [15:0] div;
logic        rx_full, overrun, perr, ferr;
logic  [7:0] rx_data;

// ------------------------------------------------------------------ 7 MHz reference
// clk is 32 x the 1 MHz bus clock: PAL 31.53 MHz (/ 4.44 = 7.09 MHz), NTSC
// 32.73 MHz (/ 4.57 = 7.16 MHz)
logic [5:0] ref_acc;
logic       ref_tick;
always_ff @(posedge clk) begin
	ref_tick <= 1'b0;
	if (ref_acc + (ntsc ? 6'd7 : 6'd9) >= (ntsc ? 6'd32 : 6'd40)) begin
		ref_acc  <= ref_acc + (ntsc ? 6'd7 : 6'd9) - (ntsc ? 6'd32 : 6'd40);
		ref_tick <= 1'b1;
	end
	else ref_acc <= ref_acc + (ntsc ? 6'd7 : 6'd9);
end

// 16x bit clock
logic [15:0] div_cnt;
logic        x16;
always_ff @(posedge clk) begin
	x16 <= 1'b0;
	if (ref_tick) begin
		if (div_cnt == 16'd0) begin div_cnt <= div; x16 <= 1'b1; end
		else div_cnt <= div_cnt - 16'd1;
	end
end

wire [3:0] nbits = 4'd8 - {2'd0, fmt[3:2]};

// ------------------------------------------------------------------ transmitter
logic        tx_full;          // holding register occupied
logic  [7:0] tx_hold;
logic        tx_busy;
logic  [3:0] tx_phase;         // 16 x16 ticks per bit
logic  [3:0] tx_bit;           // 0 start, 1..n data, then parity, then stop
logic  [7:0] tx_sh;
logic        tx_par;

always_ff @(posedge clk) begin
	if (reset) begin
		txd <= 1'b1; tx_full <= 1'b0; tx_busy <= 1'b0; tx_phase <= '0; tx_bit <= '0;
	end
	else begin
		// bytes written while sending is disabled are dropped (the KERNAL touches $D600 at start-up)
		if (reg_we && reg_addr == 3'd0 && fmt[7]) begin tx_hold <= reg_din; tx_full <= 1'b1; end
		if (!fmt[7]) tx_full <= 1'b0;

		if (x16) begin
			if (!tx_busy) begin
				if (tx_full && fmt[7]) begin
					tx_sh <= tx_hold; tx_full <= 1'b0; tx_busy <= 1'b1;
					tx_bit <= 4'd0; tx_phase <= 4'd0; tx_par <= fmt[0];
					txd <= 1'b0;                                   // start bit
				end
			end
			else begin
				tx_phase <= tx_phase + 4'd1;
				if (tx_phase == 4'd15) begin
					tx_bit <= tx_bit + 4'd1;
					if (tx_bit < nbits) begin                     // next data bit
						txd    <= tx_sh[0];
						tx_par <= tx_par ^ tx_sh[0];
						tx_sh  <= {1'b0, tx_sh[7:1]};
					end
					else if (tx_bit == nbits && fmt[1]) txd <= tx_par;      // parity
					else if (tx_bit == nbits + {3'd0, fmt[1]}) txd <= 1'b1; // stop bit
					else tx_busy <= 1'b0;                                   // stop bit sent
				end
			end
		end
	end
end

// ------------------------------------------------------------------ receiver
logic [2:0] rx_sync;
wire        rx = rx_sync[2];
logic       rx_busy;
logic [3:0] rx_phase, rx_bit;
logic [7:0] rx_sh;
logic       rx_par;

always_ff @(posedge clk) rx_sync <= {rx_sync[1:0], rxd};

always_ff @(posedge clk) begin
	if (reset) begin
		rx_busy <= 1'b0; rx_full <= 1'b0; overrun <= 1'b0; perr <= 1'b0; ferr <= 1'b0;
	end
	else begin
		if ((reg_re && reg_addr == 3'd0) || (reg_we && reg_addr == 3'd1)) begin
			rx_full <= 1'b0; overrun <= 1'b0; perr <= 1'b0; ferr <= 1'b0;
		end

		if (x16 && fmt[6]) begin
			if (!rx_busy) begin
				if (!rx) begin rx_busy <= 1'b1; rx_phase <= 4'd0; rx_bit <= 4'd0; end
			end
			else begin
				rx_phase <= rx_phase + 4'd1;
				if (rx_phase == 4'd7) begin                         // middle of the bit
					rx_bit <= rx_bit + 4'd1;
					if (rx_bit == 4'd0) begin
						if (rx) rx_busy <= 1'b0;                      // glitch, not a start bit
						rx_par <= fmt[0];
						rx_sh  <= '0;
					end
					else if (rx_bit <= nbits) begin
						rx_sh  <= {rx, rx_sh[7:1]};
						rx_par <= rx_par ^ rx;
					end
					else if (rx_bit == nbits + 4'd1 && fmt[1]) rx_par <= rx_par ^ rx;
					else begin
						// stop bit: deliver the byte, right aligned
						rx_busy <= 1'b0;
						rx_data <= rx_sh >> (4'd8 - nbits);
						if (rx_full) overrun <= 1'b1;
						rx_full <= 1'b1;
						ferr    <= !rx;
						perr    <= fmt[1] && rx_par;
					end
				end
			end
		end
	end
end

// ------------------------------------------------------------------ registers
always_ff @(posedge clk) begin
	if (reset) begin fmt <= '0; imask <= '0; div <= 16'd46; end
	else if (reg_we) begin
		case (reg_addr)
			3'd2: fmt        <= reg_din;
			3'd3: div[7:0]   <= reg_din;
			3'd4: div[15:8]  <= reg_din;
			3'd5: imask      <= reg_din;
			default: ;
		endcase
	end
end

wire [7:0] status = {!tx_full && !tx_busy, !tx_full, 2'b00, ferr, perr, overrun, rx_full};
wire [7:0] iflags = {!tx_full, rx_full, 6'd0};

assign irq_n = !(|(iflags & imask & 8'hC0));

always_comb begin
	case (reg_addr)
		3'd0: reg_dout = rx_data;
		3'd1: reg_dout = status;
		3'd2: reg_dout = fmt;
		3'd3: reg_dout = div[7:0];
		3'd4: reg_dout = div[15:8];
		3'd5: reg_dout = imask;
		3'd6: reg_dout = iflags;
		default: reg_dout = 8'h00;
	endcase
end

endmodule
