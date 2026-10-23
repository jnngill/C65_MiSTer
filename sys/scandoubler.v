//
// scandoubler.v
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// Copyright (c) 2017-2021 Alexey Melnikov
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 

// TODO: Delay vsync one line

module scandoubler #(parameter LENGTH, parameter HALF_DEPTH)
(
	// system interface
	input             clk_vid,
	input             hq2x,

	// shifter video interface
	input             ce_pix,
	input             hs_in,
	input             vs_in,
	input             hb_in,
	input             vb_in,
	input  [DWIDTH:0] r_in,
	input  [DWIDTH:0] g_in,
	input  [DWIDTH:0] b_in,

	// output interface
	output            ce_pix_out,
	output reg        hs_out,
	output            vs_out,
	output            hb_out,
	output            vb_out,
	output [DWIDTH:0] r_out,
	output [DWIDTH:0] g_out,
	output [DWIDTH:0] b_out
);

localparam DWIDTH = HALF_DEPTH ? 3 : 7;

reg  [7:0] pix_len = 0;
wire [7:0] pl = pix_len + 1'b1;

reg  [7:0] pix_in_cnt = 0;
wire [7:0] pc_in = pix_in_cnt + 1'b1;
reg  [7:0] pixsz, pixsz2, pixsz4 = 0;

reg ce_x4i, ce_x1i;
always @(posedge clk_vid) begin
	reg old_ce, valid, hs;

	if(~&pix_len) pix_len <= pl;
	if(~&pix_in_cnt) pix_in_cnt <= pc_in;

	ce_x4i <= 0;
	ce_x1i <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if((pc_in == pixsz4) || (pc_in == pixsz2) || (pc_in == (pixsz2+pixsz4))) ce_x4i <= 1;

	old_ce <= ce_pix;
	if(~old_ce & ce_pix) begin
		if(valid & ~hb_in & ~vb_in) begin
			pixsz  <= pl;
			pixsz2 <= {1'b0,  pl[7:1]};
			pixsz4 <= {2'b00, pl[7:2]};
		end
		pix_len <= 0;
		valid <= 1;
	end

	hs <= hs_in;
	if((~hs & hs_in) || (pc_in >= pixsz)) begin
		ce_x4i <= 1;
		ce_x1i <= 1;
		pix_in_cnt <= 0;
	end

	if(hb_in | vb_in) valid <= 0;
end

reg req_line_reset;
reg [DWIDTH:0] r_d, g_d, b_d;
always @(posedge clk_vid) begin
	if(ce_x1i) begin
		req_line_reset <= hb_in;
		r_d <= r_in;
		g_d <= g_in;
		b_d <= b_in;
	end
end

// C65 core: HQ2x is not built (it needs ~58 memory blocks).  A plain line
// doubler instead: each input line is written to one of two line buffers and
// the previous line is read out twice, at double rate.
localparam AW = $clog2(LENGTH);
reg [DWIDTH*3+2:0] lbuf [0:(2<<AW)-1];
reg [DWIDTH*3+2:0] lb_q;
reg          lb_wl;          // line buffer being written
reg          lb_rl;          // line buffer being read, chosen at the start of each output line
reg [AW-1:0] lb_wx, lb_rx;
always @(posedge clk_vid) begin
	reg hb_d;
	if (ce_x1i) begin
		hb_d <= hb_in;
		if (hb_in) lb_wx <= 0;
		else begin
			lbuf[{lb_wl, lb_wx}] <= {b_in, g_in, r_in};
			if (~&lb_wx) lb_wx <= lb_wx + 1'd1;
		end
		if (hb_in & ~hb_d) lb_wl <= ~lb_wl;          // line complete
	end
	if (ce_x2o) begin
		lb_q <= lbuf[{lb_rl, lb_rx}];
		if (hbo[0]) begin lb_rx <= 0; lb_rl <= ~lb_wl; end
		else if (~&lb_rx) lb_rx <= lb_rx + 1'd1;
	end
end
assign {b_out, g_out, r_out} = lb_q;

reg  [7:0] pix_out_cnt = 0;
wire [7:0] pc_out = pix_out_cnt + 1'b1;

reg ce_x4o, ce_x2o;
always @(posedge clk_vid) begin
	reg hs;

	if(~&pix_out_cnt) pix_out_cnt <= pc_out;

	ce_x4o <= 0;
	ce_x2o <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if((pc_out == pixsz4) || (pc_out == pixsz2) || (pc_out == (pixsz2+pixsz4))) ce_x4o <= 1;
	if( pc_out == pixsz2) ce_x2o <= 1;

	hs <= hs_out;
	if((~hs & hs_out) || (pc_out >= pixsz)) begin
		ce_x2o <= 1;
		ce_x4o <= 1;
		pix_out_cnt <= 0;
	end
end

reg [1:0] sd_line;
reg [3:0] vbo;
reg [3:0] vso;
reg [8:0] hbo;
always @(posedge clk_vid) begin

	reg [31:0] hcnt;
	reg [30:0] sd_hcnt;
	reg [30:0] hs_start, hs_end;
	reg [30:0] hde_start, hde_end;

	reg hs, hb;

	if(ce_x4o) begin
		hbo[8:1] <= hbo[7:0];
	end

	// output counter synchronous to input and at twice the rate
	sd_hcnt <= sd_hcnt + 1'd1;
	if(sd_hcnt == hde_start) begin
		sd_hcnt <= 0;
		vbo[3:1] <= vbo[2:0];
	end

	if(sd_hcnt == hs_end) begin
		sd_line <= sd_line + 1'd1;
		if(&vbo[3:2]) sd_line <= 1;
		vso[3:1] <= vso[2:0];
	end

	if(sd_hcnt == hde_start)hbo[0] <= 0;
	if(sd_hcnt == hde_end)  hbo[0] <= 1;

	// replicate horizontal sync at twice the speed
	if(sd_hcnt == hs_end)   hs_out <= 0;
	if(sd_hcnt == hs_start) hs_out <= 1;

	hs <= hs_in;
	hb <= hb_in;

	hcnt <= hcnt + 1'd1;
	if(hb && !hb_in) begin
		hde_start <= hcnt[31:1];
		hbo[0] <= 0;
		hcnt <= 0;
		sd_hcnt <= 0;
		vbo <= {vbo[2:0],vb_in};
	end

	if(!hb && hb_in) hde_end <= hcnt[31:1];

	// falling edge of hsync indicates start of line
	if(hs && !hs_in) begin
		hs_end <= hcnt[31:1];
		vso[0] <= vs_in;
	end

	// save position of rising edge
	if(!hs && hs_in) hs_start <= hcnt[31:1];
end

assign vs_out = vso[3];
assign ce_pix_out = ce_x2o;

//Compensate picture shift after the line doubler (one output pixel)
assign vb_out = vbo[3];
assign hb_out = hbo[2];

endmodule
