// MEGA65 real-time clock registers ($FFD7110-$FFD7116), read only.
//
//   +0 seconds  +1 minutes  +2 hours (bit 7 set = 24 hour format)
//   +3 day      +4 month    +5 year (two digits)   +6 day of week
//
// All values are BCD.  The clock is loaded from the MiSTer RTC word
// (MSM6242B layout; bit 64 toggles whenever the HPS sends the time) and then
// kept running here.

module m65_rtc (
	input  logic        clk,
	input  logic        ntsc,        // selects the clk frequency used for the 1 Hz tick
	input  logic [64:0] rtc,
	input  logic  [3:0] reg_addr,
	output logic  [7:0] reg_dout
);

logic [7:0] sec = 8'h00, min = 8'h00, hour = 8'h00, day = 8'h01, month = 8'h01, year = 8'h00;
logic [2:0] wday = 3'd0;
logic       rtc_flag = 1'b0;
logic [24:0] div = '0;

function automatic [7:0] bcd_inc(input logic [7:0] v);
	bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
endfunction

// last day of the current month (BCD)
logic [7:0] last_day;
wire        leap = (year[0] == 1'b0) && (year[4] == year[1]);   // BCD year divisible by 4
always_comb begin
	case (month)
		8'h02:                      last_day = leap ? 8'h29 : 8'h28;
		8'h04, 8'h06, 8'h09, 8'h11: last_day = 8'h30;
		default:                    last_day = 8'h31;
	endcase
end

wire [24:0] clk_hz = ntsc ? 25'd32727272 : 25'd31527954;

always_ff @(posedge clk) begin
	div <= div + 25'd1;
	if (div == clk_hz - 25'd1) begin
		div <= '0;
		sec <= bcd_inc(sec);
		if (sec == 8'h59) begin
			sec <= 8'h00;
			min <= bcd_inc(min);
			if (min == 8'h59) begin
				min  <= 8'h00;
				hour <= bcd_inc(hour);
				if (hour == 8'h23) begin
					hour <= 8'h00;
					wday <= (wday == 3'd6) ? 3'd0 : wday + 3'd1;
					day  <= bcd_inc(day);
					if (day == last_day) begin
						day   <= 8'h01;
						month <= bcd_inc(month);
						if (month == 8'h12) begin
							month <= 8'h01;
							year  <= bcd_inc(year);
							if (year == 8'h99) year <= 8'h00;
						end
					end
				end
			end
		end
	end

	// (re)load whenever the HPS delivers the time
	rtc_flag <= rtc[64];
	if (rtc_flag != rtc[64]) begin
		sec   <= rtc[7:0];
		min   <= rtc[15:8];
		hour  <= rtc[23:16];
		day   <= rtc[31:24];
		month <= rtc[39:32];
		year  <= rtc[47:40];
		wday  <= rtc[50:48];
		div   <= '0;
	end
end

always_comb begin
	case (reg_addr)
		4'd0:    reg_dout = sec;
		4'd1:    reg_dout = min;
		4'd2:    reg_dout = {1'b1, hour[6:0]};
		4'd3:    reg_dout = day;
		4'd4:    reg_dout = month;
		4'd5:    reg_dout = year;
		4'd6:    reg_dout = {5'd0, wday};
		default: reg_dout = 8'h00;
	endcase
end

endmodule
