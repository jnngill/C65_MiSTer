// MEGA65 Ethernet controller ($D6E0-$D6EF, buffers at $FFDE800-$FFDEFFF),
// bridged to the MiSTer's network through DDR3 and the MiSTer NetBridge helper
// (github.com/jnngill/MiSTer_NetBridge, docs/PROTOCOL.md there).
//
// The DE10-Nano has no Ethernet PHY the FPGA can reach, so frames go through
// the ARM side: the helper there moves them between eth0 and the shared area
// at ARM address 0x3FF00000 (DDR word address 0x7FE0000):
//
//   +0x0000  word 0, written by the core:
//              [7:0] 0xE7 magic   [15:8] version 2   [23:16] rx_req   [31:24] rx_slot
//              [39:32] tx_seq     [51:40] tx_len     [63:56] flags: bit 0 running
//   +0x0008  word 1, written by the daemon:
//              [7:0] rx_done      [15:8] tx_done     [23:16] 0xA5 while it runs
//   +0x0010  word 2, written by the core: [47:0] MAC (first byte in [7:0]),
//              [55:48] $D6E5 (bit 0 filter unicast, 4 accept broadcast, 5 multicast)
//   +0x0018  word 3, written by the core: "MiSTNet" and a heartbeat byte that
//              changes on every poll; the helper serves the area only while
//              it moves, so it leaves other cores' DDR alone
//   +0x0800  TX buffer (2K)
//   +0x1000  RX buffers 0-3 (2K each)
//
// RX: when the core has a free buffer it asks for a frame (rx_req + 1, the
// buffer in rx_slot); the daemon writes the frame there in the MEGA65 layout
// (bytes 0 / 1: length incl. the 4 CRC bytes and the flags of $D6E1 status
// byte, the frame from byte 2) and answers with rx_done = rx_req.  TX: STARTTX
// publishes tx_seq + 1 and the length; the daemon sends the frame and answers
// with tx_done = tx_seq.  Without a daemon a frame still "goes out" after a
// timeout, as on a MEGA65 with no cable.
//
// The RX buffer rotation, the free buffer count and the interrupts follow
// ethernet.vhdl of the MEGA65 project (MEGA65/mega65-core).

module m65_eth (
	input  logic        clk,
	input  logic        reset,

	input  logic  [3:0] reg_addr,     // $D6Ex
	input  logic        reg_we,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,

	// $FFDE800-$FFDEFFF: reads see the current RX buffer, writes fill the TX buffer
	input  logic        buf_req,      // held until buf_ack
	input  logic        buf_we,
	input  logic [10:0] buf_addr,
	input  logic  [7:0] buf_din,
	output logic  [7:0] buf_dout,     // valid with buf_ack
	output logic        buf_ack,

	output logic        irq_n,

	// DDR3 (one 64-bit word per access)
	output logic [28:0] ddr_addr,
	output logic        ddr_rd,
	output logic        ddr_we,
	output logic [63:0] ddr_din,
	output logic  [7:0] ddr_be,
	input  logic        ddr_busy,
	input  logic [63:0] ddr_dout,
	input  logic        ddr_dout_ready
);

localparam logic [28:0] BASE   = 29'h7FE0000;
localparam int          NBUF   = 4;

// ------------------------------------------------------------------ registers
logic        run;                 // $D6E0 bit 0 (0 = held in reset)
logic        irqen_rx, irqen_tx, irq_rx, irq_tx, stream;
logic [11:0] tx_size;
logic  [7:0] d6e5;
logic  [4:0] miim_reg;
logic  [2:0] miim_phy;
logic [47:0] mac;
logic        last_rot;
logic  [1:0] cpuside, ethside;
logic        tx_busy;
logic  [7:0] rx_req, rx_done, tx_seq, tx_done;
logic  [1:0] rx_slot;
logic        rx_wait;             // a frame has been asked for (rx_req / rx_slot)
logic        daemon;              // the daemon's 0xA5 is there
logic        init;                // word 1 not read yet
logic        pub_req, mac_we;     // word 0 / word 2 changed

wire  [1:0] cpu1    = cpuside + 2'd1;
wire        blocked = ethside == cpuside;
wire  [2:0] nfree   = blocked ? 3'd0 : (cpuside > ethside) ? {1'b0, cpuside - ethside} : 3'(NBUF) + cpuside - ethside;

// an emulated PHY: 100 Mbit/s full duplex, auto-negotiation done, link up while the daemon runs
function automatic [15:0] phy_reg(input logic [4:0] r, input logic link);
	case (r)
		5'd0:    phy_reg = 16'h3100;
		5'd1:    phy_reg = {16'h7869 | (link ? 16'h0024 : 16'h0000)};
		5'd2:    phy_reg = 16'h0007;
		5'd3:    phy_reg = 16'hC0F1;
		5'd4:    phy_reg = 16'h01E1;
		5'd5:    phy_reg = link ? 16'h45E1 : 16'h0000;
		default: phy_reg = 16'h0000;
	endcase
endfunction

always_comb begin
	logic [15:0] p;
	p = phy_reg(miim_reg, daemon);
	case (reg_addr)
		4'h0: reg_dout = {!tx_busy, blocked, 1'b0, 1'b0, 1'b0, 2'b00, run};
		4'h1: reg_dout = {irqen_rx, irqen_tx, irq_rx, irq_tx, stream, (nfree >= 3'd3) ? 2'd3 : nfree[1:0], 1'b0};
		4'h2: reg_dout = tx_size[7:0];
		4'h3: reg_dout = {4'b0000, tx_size[11:8]};
		4'h4: reg_dout = 8'(NBUF);
		4'h5: reg_dout = d6e5;
		4'h6: reg_dout = {miim_phy, miim_reg};
		4'h7: reg_dout = p[7:0];
		4'h8: reg_dout = p[15:8];
		4'h9: reg_dout = mac[47:40];
		4'hA: reg_dout = mac[39:32];
		4'hB: reg_dout = mac[31:24];
		4'hC: reg_dout = mac[23:16];
		4'hD: reg_dout = mac[15:8];
		4'hE: reg_dout = mac[7:0];
		default: reg_dout = 8'hFF;
	endcase
end

assign irq_n = !((irqen_rx && irq_rx) || (irqen_tx && irq_tx));

// ------------------------------------------------------------------ DDR side
typedef enum logic [2:0] { D_IDLE, D_BUFRD, D_BUFWR, D_POLL, D_PUB0, D_PUB2, D_WAIT } dstate_t;
dstate_t     dst, dret;
logic [14:0] poll_cnt;            // ~1 ms between looks at the daemon's word
logic [21:0] tx_to;               // TX timeout: ~33 ms without a daemon, ~130 ms with one
logic        pub0, pub2;          // word 0 / 2 need writing
logic        beat;                // heartbeat written, the poll read is next
logic  [7:0] hb;
logic  [7:0] last_d6e5;
logic        cache_ok;            // the last RX word read, while the CPU stays on that buffer
logic  [9:0] cache_tag;           // {buffer, word}
logic [63:0] cache;
logic  [1:0] last_cpuside;
logic        rx_got, tx_got;      // the daemon answered (from D_POLL)

wire [9:0] want_tag = {cpuside, buf_addr[10:3]};

always_ff @(posedge clk) begin
	buf_ack <= 1'b0;
	rx_got  <= 1'b0;
	tx_got  <= 1'b0;
	if (reset) begin
		dst <= D_IDLE; ddr_rd <= 1'b0; ddr_we <= 1'b0; poll_cnt <= '0; cache_ok <= 1'b0;
		init <= 1'b1; daemon <= 1'b0; pub0 <= 1'b1; pub2 <= 1'b1; beat <= 1'b0; hb <= 8'd0;
	end
	else begin
		if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;
		if (ddr_we && !ddr_busy) ddr_we <= 1'b0;
		if (poll_cnt != 0) poll_cnt <= poll_cnt - 1'd1;
		last_cpuside <= cpuside;
		if (cpuside != last_cpuside || !run) cache_ok <= 1'b0;
		case (dst)
			D_IDLE:
				if (buf_req && !buf_ack && !buf_we && cache_ok && want_tag == cache_tag) begin
					buf_dout <= cache[{buf_addr[2:0], 3'b000} +: 8]; buf_ack <= 1'b1;
				end
				else if (buf_req && !buf_ack && !buf_we) begin
					ddr_addr <= BASE + 29'h200 + {19'd0, want_tag}; ddr_rd <= 1'b1; cache_tag <= want_tag;
					dst <= D_WAIT; dret <= D_BUFRD;
				end
				else if (buf_req && !buf_ack) begin
					ddr_addr <= BASE + 29'h100 + {21'd0, buf_addr[10:3]}; ddr_we <= 1'b1;
					ddr_din <= {8{buf_din}}; ddr_be <= 8'b1 << buf_addr[2:0];
					dst <= D_BUFWR;
				end
				else if (pub0 && !init) begin
					ddr_addr <= BASE; ddr_we <= 1'b1; ddr_be <= 8'hFF; pub0 <= 1'b0;
					ddr_din <= {7'd0, run, 4'd0, tx_size, tx_seq, 6'd0, rx_slot, rx_req, 8'h02, 8'hE7};
					dst <= D_PUB0;
				end
				else if (pub2 && !init) begin
					ddr_addr <= BASE + 29'd2; ddr_we <= 1'b1; ddr_be <= 8'hFF; pub2 <= 1'b0;
					ddr_din <= {8'd0, d6e5, mac[7:0], mac[15:8], mac[23:16], mac[31:24], mac[39:32], mac[47:40]};
					dst <= D_PUB2;
				end
				else if (poll_cnt == 0 && !beat && !init) begin
					// heartbeat: "MiSTNet" ('M' first) and a byte that keeps changing
					ddr_addr <= BASE + 29'd3; ddr_we <= 1'b1; ddr_be <= 8'hFF; beat <= 1'b1;
					ddr_din <= {hb + 8'd1, 56'h74_65_4E_54_53_69_4D}; hb <= hb + 8'd1;
					dst <= D_PUB2;
				end
				else if (poll_cnt == 0) begin
					ddr_addr <= BASE + 29'd1; ddr_rd <= 1'b1; poll_cnt <= '1; beat <= 1'b0;
					dst <= D_WAIT; dret <= D_POLL;
				end
			D_WAIT:
				if (!ddr_rd && ddr_dout_ready) begin
					if (dret == D_BUFRD) begin
						cache <= ddr_dout; cache_ok <= 1'b1;
						buf_dout <= ddr_dout[{buf_addr[2:0], 3'b000} +: 8]; buf_ack <= 1'b1;
					end
					else begin
						daemon <= ddr_dout[23:16] == 8'hA5;
						if (init) begin
							// carry on from whatever the daemon last answered
							rx_done <= ddr_dout[7:0]; tx_done <= ddr_dout[15:8]; init <= 1'b0;
						end
						else begin
							if (ddr_dout[7:0] != rx_done)  begin rx_done <= ddr_dout[7:0];  rx_got <= 1'b1; end
							if (ddr_dout[15:8] != tx_done) begin tx_done <= ddr_dout[15:8]; tx_got <= 1'b1; end
						end
					end
					dst <= D_IDLE;
				end
			D_BUFWR, D_PUB0, D_PUB2:
				if (!ddr_we) begin
					if (dst == D_BUFWR) buf_ack <= 1'b1;
					dst <= D_IDLE;
				end
			default: dst <= D_IDLE;
		endcase
		// anything the daemon needs to see again
		if (pub_req) pub0 <= 1'b1;
		if (d6e5 != last_d6e5 || mac_we) pub2 <= 1'b1;
		last_d6e5 <= d6e5;
	end
end

// ------------------------------------------------------------------ controller
always_ff @(posedge clk) begin
	pub_req <= 1'b0;
	mac_we  <= 1'b0;
	if (reset) begin
		run <= 1'b1; irqen_rx <= 1'b0; irqen_tx <= 1'b0; irq_tx <= 1'b0; stream <= 1'b0;
		tx_size <= 12'd98; d6e5 <= 8'h00; miim_reg <= '0; miim_phy <= '0;
		mac <= 48'h024753656565; last_rot <= 1'b0;
		cpuside <= 2'd0; ethside <= 2'd1; tx_busy <= 1'b0; tx_to <= '0;
		rx_req <= 8'd0; tx_seq <= 8'd0; rx_slot <= 2'd1; rx_wait <= 1'b0;
	end
	else begin
		if (init && dst == D_WAIT && dret == D_POLL && !ddr_rd && ddr_dout_ready) begin
			rx_req <= ddr_dout[7:0]; tx_seq <= ddr_dout[15:8]; pub_req <= 1'b1;
		end

		// a frame has arrived in rx_slot
		if (rx_got && rx_wait && rx_done == rx_req) begin
			rx_wait <= 1'b0;
			if (rx_slot == ethside && run) ethside <= ethside + 2'd1;
		end
		// ask for the next one into the buffer the controller writes next
		if (!init && !rx_wait && !rx_got && run && !blocked && daemon) begin
			rx_wait <= 1'b1; rx_req <= rx_req + 8'd1; rx_slot <= ethside; pub_req <= 1'b1;
		end

		// TX
		if (tx_busy) begin
			tx_to <= tx_to + 1'd1;
			if ((tx_got && tx_done == tx_seq) || (daemon ? &tx_to : &tx_to[19:0])) begin tx_busy <= 1'b0; irq_tx <= 1'b1; end
		end

		irq_rx <= cpu1 != ethside;

		if (reg_we) case (reg_addr)
			4'h0: begin
				run <= reg_din[0];
				if (!reg_din[0] || !reg_din[1]) begin cpuside <= 2'd0; ethside <= 2'd1; end
				pub_req <= 1'b1;
			end
			4'h1: begin
				irqen_rx <= reg_din[7]; irqen_tx <= reg_din[6]; stream <= reg_din[3];
				last_rot <= reg_din[1];
				if (reg_din[1] && !last_rot) begin
					// next received frame (ethernet.vhdl's rotation)
					// (when it has caught up, ethernet.vhdl points it at ethside - 1, where it already is)
					if (cpu1 != ethside) cpuside <= cpu1;
				end
			end
			4'h2: tx_size[7:0]  <= reg_din;
			4'h3: tx_size[11:8] <= reg_din[3:0];
			4'h4: case (reg_din)
				8'h00: ;                                      // STOPTX: the frame has gone already
				8'h01: if (!tx_busy) begin
					tx_busy <= 1'b1; tx_to <= '0; irq_tx <= 1'b0;
					tx_seq <= tx_seq + 8'd1; pub_req <= 1'b1;
				end
				default: ;
			endcase
			4'h5: d6e5 <= reg_din;
			4'h6: begin miim_reg <= reg_din[4:0]; miim_phy <= reg_din[7:5]; end
			4'h9: begin mac[47:40] <= reg_din; mac_we <= 1'b1; end
			4'hA: begin mac[39:32] <= reg_din; mac_we <= 1'b1; end
			4'hB: begin mac[31:24] <= reg_din; mac_we <= 1'b1; end
			4'hC: begin mac[23:16] <= reg_din; mac_we <= 1'b1; end
			4'hD: begin mac[15:8]  <= reg_din; mac_we <= 1'b1; end
			4'hE: begin mac[7:0]   <= reg_din; mac_we <= 1'b1; end
			default: ;
		endcase
	end
end

endmodule
