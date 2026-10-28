// MEGA65 audio DMA: four sample playback channels, $D711-$D75F.
//
// Each channel has a 24-bit base address, a 16-bit top address, a 24-bit
// frequency and a volume.  The frequency is added to a 24-bit timing counter
// at the MEGA65's 40.5 MHz; every carry out fetches the next sample from
// memory.  When the current address reaches the top address the channel loops
// back to the base address or stops (EN cleared, STP set).  Enabling a
// channel starts it at the base address, unless the program has written the
// current address ($D72A-$D72C) since the channel last stopped; some
// programs start samples that way and never set the base.  Samples are 16 bit,
// 8 bit or one nybble per byte, signed or unsigned.  Channels 0 and 1 play on
// the left, 2 and 3 on the right; $D71C-$D71F add each channel to the other
// side as well.
//
// Samples are read from the first 16 MB as on the MEGA65 (whose audio DMA
// addresses are 24 bits, so attic RAM is out of reach); here that is chip
// RAM and the ROM area below $60000.  The core lends this unit one bus clock
// per byte (fetch_req -> fetch_gnt, with the byte on fetch_q the clock after
// the grant).  Sine mode ($D72x bit 4) plays the MEGA65's 32-step sine table,
// one step per sample period, instead of reading memory.
//
// Interrupts ($D713 / $D714-$D717): an enabled channel raises its flag once
// its current address (low 16 bits) reaches top - offset * 256; that clears
// its enable, so each arming gives one interrupt.  The MEGA65 pulses its IRQ
// for the event; here irq_n is held low until $D713 is read or written (or for
// at most ~2 ms), so the CPU sees it at its next instruction.
//
// clk is the ~31.5 MHz system clock; the counters advance by 1.28125 x the
// frequency per clk, matching 40.5 MHz to 0.3%.

module m65_audio (
	input  logic        clk,
	input  logic        reset,

	input  logic  [6:0] reg_addr,      // $D700 + reg_addr, only $11-$5F are used here
	input  logic        reg_we,
	input  logic  [7:0] reg_din,
	input  logic        reg_re,
	output logic  [7:0] reg_dout,
	output logic        irq_n,

	output logic        fetch_req,
	output logic [23:0] fetch_addr,
	input  logic        fetch_gnt,
	input  logic  [7:0] fetch_q,

	output logic signed [15:0] out_l, out_r
);

logic        auden;
logic  [7:0] ctl     [4];      // $D720: [7] EN [6] LOOP [5] unsigned [4] sine [3] STP [1:0] bits
logic [23:0] base    [4];
logic [23:0] freq    [4];
logic [15:0] top     [4];
logic  [7:0] vol     [4];
logic  [7:0] xvol    [4];      // $D71C-$D71F: volume on the other side
logic [23:0] cur     [4];
logic  [3:0] cur_set;          // current address written by the program
logic [23:0] tmg     [4];
logic signed [15:0] smp [4];
logic  [3:0] pend;             // a sample is due
logic  [7:0] r711, r712;
logic  [3:0] irqenb, irqflg;   // $D713: [7:4] flags of channels 0-3, [3:0] enables of channels 0-3 (bit 3 = channel 0)
logic  [7:0] irqofs [4];       // $D714-$D717
logic        irq_act;
logic [15:0] irq_tmo;

// the MEGA65's sine table: 32 signed steps
function automatic [7:0] sine(input logic [4:0] i);
	case (i[3:0])
		4'd0: sine = 8'd0;   4'd1: sine = 8'd24;  4'd2: sine = 8'd48;  4'd3: sine = 8'd70;
		4'd4: sine = 8'd89;  4'd5: sine = 8'd105; 4'd6: sine = 8'd117; 4'd7: sine = 8'd124;
		4'd8: sine = 8'd127; 4'd9: sine = 8'd124; 4'd10: sine = 8'd117; 4'd11: sine = 8'd105;
		4'd12: sine = 8'd89; 4'd13: sine = 8'd70; 4'd14: sine = 8'd48; default: sine = 8'd24;
	endcase
	if (i[4]) sine = (i[3:0] == 4'd0) ? 8'd0 : (i[3:0] == 4'd8) ? 8'h81 : 8'(-$signed(sine) - 8'sd1);
endfunction

// fetch sequencer
logic  [1:0] f_ch;
logic        f_busy, f_hi, f_wait;
logic  [7:0] f_lo;

wire [1:0] f_bits = ctl[f_ch][1:0];

// address of the sample after the one at a
function automatic [23:0] step(input logic [23:0] a, input logic [1:0] bits);
	step = a + ((bits == 2'b11) ? 24'd2 : 24'd1);
endfunction

always_ff @(posedge clk) begin
	if (reset) begin
		auden <= 1'b0; r711 <= '0; r712 <= '0; pend <= '0; cur_set <= '0;
		irqenb <= '0; irqflg <= '0; irq_act <= 1'b0; irq_tmo <= '0;
		for (int i = 0; i < 4; i++) irqofs[i] <= '0;
		f_busy <= 1'b0; f_hi <= 1'b0; f_wait <= 1'b0; fetch_req <= 1'b0;
		for (int i = 0; i < 4; i++) begin
			ctl[i] <= '0; base[i] <= '0; freq[i] <= '0; top[i] <= '0; vol[i] <= '0; xvol[i] <= '0;
			cur[i] <= '0; tmg[i] <= '0; smp[i] <= '0;
		end
	end
	else begin
		// timing counters
		for (int i = 0; i < 4; i++) begin
			logic [24:0] t;
			t = {1'b0, tmg[i]} + {1'b0, freq[i]} + {3'b0, freq[i][23:2]} + {6'b0, freq[i][23:5]};
			if (auden && ctl[i][7]) begin
				tmg[i] <= t[23:0];
				if (t[24]) begin
					if (ctl[i][4]) begin
						// sine mode: next table step, no memory read
						smp[i] <= {sine(cur[i][4:0]), sine(cur[i][4:0])};
						cur[i] <= cur[i] + 24'd1;
					end
					else pend[i] <= 1'b1;
				end
			end
		end

		// interrupts: one per arming, when the address nears the top
		if (irq_act) irq_tmo <= irq_tmo + 16'd1;
		if (&irq_tmo) irq_act <= 1'b0;
		for (int i = 0; i < 4; i++)
			if (irqenb[3-i] && ctl[i][7] && cur[i][15:0] >= {top[i][15:8] - irqofs[i], 8'h00}) begin
				irqflg[3-i] <= 1'b1;
				irqenb[3-i] <= 1'b0;
				irq_act <= 1'b1; irq_tmo <= '0;
			end
		if (reg_re && reg_addr == 7'h13) irq_act <= 1'b0;

		// fetch one byte at a time from the pending channels
		if (!f_busy) begin
			for (int i = 3; i >= 0; i--)
				if (pend[i]) begin f_ch <= 2'(i); f_busy <= 1'b1; f_hi <= 1'b0; end
		end
		else if (!fetch_req && !f_wait) begin
			fetch_addr <= f_hi ? cur[f_ch] + 24'd1 : cur[f_ch];
			// only chip RAM ($00000-$5FFFF) can be read
			if ((f_hi ? cur[f_ch] + 24'd1 : cur[f_ch]) < 24'h060000) fetch_req <= 1'b1;
			else begin smp[f_ch] <= '0; pend[f_ch] <= 1'b0; f_busy <= 1'b0; end
		end
		if (fetch_req && fetch_gnt) begin fetch_req <= 1'b0; f_wait <= 1'b1; end
		if (f_wait) begin
			f_wait <= 1'b0;
			if (f_bits == 2'b11 && !f_hi) begin f_lo <= fetch_q; f_hi <= 1'b1; end
			else begin
				logic [15:0] s;
				case (f_bits)
					2'b11: s = {fetch_q, f_lo};
					2'b10: s = {fetch_q, 8'd0};
					2'b01: s = {fetch_q[7:4], 12'd0};
					default: s = {fetch_q[3:0], 12'd0};
				endcase
				if (ctl[f_ch][5]) s[15] = ~s[15];      // unsigned samples
				smp[f_ch] <= s;
				pend[f_ch] <= 1'b0;
				f_busy <= 1'b0;
				// advance; loop or stop at the top address
				// (the top address may name the last sample or the byte after it)
				if (cur[f_ch][15:0] == top[f_ch] || step(cur[f_ch], f_bits) == {cur[f_ch][23:16], top[f_ch]} ||
				    (f_bits == 2'b11 && cur[f_ch][15:0] + 16'd1 == top[f_ch])) begin
					if (ctl[f_ch][6]) cur[f_ch] <= base[f_ch];
					else begin ctl[f_ch][7] <= 1'b0; ctl[f_ch][3] <= 1'b1; smp[f_ch] <= '0; end
				end
				else cur[f_ch] <= step(cur[f_ch], f_bits);
			end
		end

		if (reg_we) begin
			case (reg_addr)
				7'h11: begin r711 <= reg_din; auden <= reg_din[7]; end
				7'h12: r712 <= reg_din;
				7'h13: begin irqflg <= reg_din[7:4]; irqenb <= reg_din[3:0]; irq_act <= 1'b0; end
				7'h14, 7'h15, 7'h16, 7'h17: irqofs[reg_addr[1:0]] <= reg_din;
				7'h1C: xvol[0] <= reg_din;
				7'h1D: xvol[1] <= reg_din;
				7'h1E: xvol[2] <= reg_din;
				7'h1F: xvol[3] <= reg_din;
				default: if (reg_addr >= 7'h20 && reg_addr < 7'h60) begin
					logic [1:0] c;
					c = 2'(reg_addr[5:4] - 2'd2);
					case (reg_addr[3:0])
						4'h0: begin
							ctl[c] <= reg_din;
							// enabling a channel starts it from the base address
							if (reg_din[7] && !ctl[c][7]) begin
								if (!cur_set[c]) cur[c] <= base[c];
								cur_set[c] <= 1'b0;
								tmg[c] <= '0;
							end
							if (!reg_din[7]) smp[c] <= '0;
						end
						4'h1: base[c][7:0]   <= reg_din;
						4'h2: base[c][15:8]  <= reg_din;
						4'h3: base[c][23:16] <= reg_din;
						4'h4: freq[c][7:0]   <= reg_din;
						4'h5: freq[c][15:8]  <= reg_din;
						4'h6: freq[c][23:16] <= reg_din;
						4'h7: top[c][7:0]    <= reg_din;
						4'h8: top[c][15:8]   <= reg_din;
						4'h9: vol[c]         <= reg_din;
						4'hA: begin cur[c][7:0]   <= reg_din; cur_set[c] <= 1'b1; end
						4'hB: begin cur[c][15:8]  <= reg_din; cur_set[c] <= 1'b1; end
						4'hC: begin cur[c][23:16] <= reg_din; cur_set[c] <= 1'b1; end
						4'hD: tmg[c][7:0]    <= reg_din;
						4'hE: tmg[c][15:8]   <= reg_din;
						4'hF: tmg[c][23:16]  <= reg_din;
					endcase
				end
			endcase
		end
	end
end

always_comb begin
	logic [1:0] c;
	c = 2'(reg_addr[5:4] - 2'd2);
	reg_dout = 8'h00;
	case (reg_addr)
		7'h11: reg_dout = {auden, r711[6:0]};
		7'h12: reg_dout = r712;
		7'h13: reg_dout = {irqflg, irqenb};
		7'h14, 7'h15, 7'h16, 7'h17: reg_dout = irqofs[reg_addr[1:0]];
		7'h1C: reg_dout = xvol[0];
		7'h1D: reg_dout = xvol[1];
		7'h1E: reg_dout = xvol[2];
		7'h1F: reg_dout = xvol[3];
		default: if (reg_addr >= 7'h20 && reg_addr < 7'h60) begin
			case (reg_addr[3:0])
				4'h0: reg_dout = ctl[c];
				4'h1: reg_dout = base[c][7:0];
				4'h2: reg_dout = base[c][15:8];
				4'h3: reg_dout = base[c][23:16];
				4'h4: reg_dout = freq[c][7:0];
				4'h5: reg_dout = freq[c][15:8];
				4'h6: reg_dout = freq[c][23:16];
				4'h7: reg_dout = top[c][7:0];
				4'h8: reg_dout = top[c][15:8];
				4'h9: reg_dout = vol[c];
				4'hA: reg_dout = cur[c][7:0];
				4'hB: reg_dout = cur[c][15:8];
				4'hC: reg_dout = cur[c][23:16];
				4'hD: reg_dout = tmg[c][7:0];
				4'hE: reg_dout = tmg[c][15:8];
				4'hF: reg_dout = tmg[c][23:16];
			endcase
		end
	endcase
end

// mixer: one multiply per clk, round robin over the 8 products
logic  [2:0] m_i;
logic signed [23:0] acc_l, acc_r;
wire  [1:0] m_ch  = m_i[1:0];
wire        m_x   = m_i[2];          // 0 = own side, 1 = the other side
wire  [7:0] m_vol = m_x ? xvol[m_ch] : vol[m_ch];
wire signed [24:0] m_p = smp[m_ch] * $signed({1'b0, m_vol});
wire        m_left = (m_ch < 2'd2) ^ m_x;

always_ff @(posedge clk) begin
	if (reset) begin m_i <= '0; acc_l <= '0; acc_r <= '0; out_l <= '0; out_r <= '0; end
	else begin
		logic signed [23:0] nl, nr;
		nl = (m_i == 3'd0) ? 24'sd0 : acc_l;
		nr = (m_i == 3'd0) ? 24'sd0 : acc_r;
		if (m_left) nl = nl + 24'(m_p >>> 8); else nr = nr + 24'(m_p >>> 8);
		acc_l <= nl; acc_r <= nr;
		if (m_i == 3'd7) begin
			// two full-volume channels per side: halve, then saturate
			out_l <= (nl >>> 1 > 24'sd32767) ? 16'sd32767 : (nl >>> 1 < -24'sd32768) ? -16'sd32768 : 16'(nl >>> 1);
			out_r <= (nr >>> 1 > 24'sd32767) ? 16'sd32767 : (nr >>> 1 < -24'sd32768) ? -16'sd32768 : 16'(nr >>> 1);
		end
		m_i <= m_i + 3'd1;
	end
end

assign irq_n = !irq_act;

endmodule
