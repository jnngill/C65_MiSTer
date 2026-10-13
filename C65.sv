//============================================================================
//  Commodore 65 for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SCALER     = 0;
assign VGA_DISABLE    = 0;
assign HDMI_FREEZE    = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = drive_led | ioctl_download;
assign BUTTONS   = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[9:8];

wire [1:0] ar = status[5:4];
assign VIDEO_ARX = (!ar) ? 13'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 13'd3 : 13'd0;

`include "build_id.v"
localparam CONF_STR = {
	"C65;;",
	"S0,D81,Mount Drive 8;",
	"F1,ROMBIN,Load System ROM;",
	"-;",
	"O[2],Video Standard,PAL,NTSC;",
	"O[5:4],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[7:6],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"O[9:8],Stereo Mix,None,25%,50%,100%;",
	"O[11:10],Keyboard Layout,US,UK,DE,Positional;",
	"O[13:12],CPU Speed,3.5 MHz,8 MHz,16 MHz;",
	"O[14],Expansion RAM,4MB (needs SDRAM),Off;",
	"O[16:15],Mouse,Port 2,Port 1,Off;",
	"O[3],DMA Revision,F018B,F018A;",
	"-;",
	"R[0],Reset;",
	"J,Fire;",
	"V,v",`BUILD_DATE
};

// ------------------------------------------------------------------ clocks
wire clk_sys, clk64, clk48;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk48),
	.outclk_1(clk64),
	.outclk_2(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(pll_locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// switch the PLL between the PAL (31.528 MHz) and NTSC (32.727 MHz) system clocks
wire ntsc = status[2];

always @(posedge CLK_50M) begin
	reg ntscd = 0, ntscd2 = 0;
	reg [2:0] state = 0;
	reg ntsc_r;

	cfg_write <= 0;

	ntscd  <= ntsc;
	ntscd2 <= ntscd;
	if (ntscd2 == ntscd && ntscd2 != ntsc_r) begin
		ntsc_r <= ntscd2;
		state  <= 1;
	end

	if (!cfg_waitrequest) begin
		if (state) state <= state + 1'd1;
		case (state)
			1: begin cfg_address <= 0; cfg_data <= 0; cfg_write <= 1; end
			3: begin cfg_address <= 7; cfg_data <= ntsc_r ? 3357876127 : 1503512573; cfg_write <= 1; end
			5: begin cfg_address <= 2; cfg_data <= 0; cfg_write <= 1; end
		endcase
	end
end

// ------------------------------------------------------------------ HPS
wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire  [21:0] gamma_bus;

wire         ioctl_download;
wire  [15:0] ioctl_index;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire  [15:0] sdram_sz;
wire  [24:0] ps2_mouse;
wire  [64:0] RTC;

wire  [31:0] sd_lba[1];
wire         sd_rd, sd_wr, sd_ack;
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[1];
wire         sd_buff_wr;
wire         img_mounted;
wire         img_readonly;
wire  [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(1), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0),

	.sd_lba(sd_lba),
	.sd_blk_cnt('{6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.sdram_sz(sdram_sz),
	.RTC(RTC)
);

// ------------------------------------------------------------------ reset / ROM load
wire rom_download = ioctl_download && (ioctl_index[5:0] <= 6'd1);
reg  rom_loaded = 0;
reg  reset;

always @(posedge clk_sys) begin
	reg [19:0] reset_cnt = '1;

	if (rom_download && ioctl_wr) rom_loaded <= 1;

	if (RESET | status[0] | buttons[1] | !pll_locked | rom_download | !rom_loaded) reset_cnt <= '1;
	else if (reset_cnt != 0) reset_cnt <= reset_cnt - 1'd1;

	reset <= (reset_cnt != 0);
end

// ------------------------------------------------------------------ expansion RAM (SDRAM module)
// The C65's expansion RAM (banks 6-15 and the 4 MB DMA region) lives in the
// first 8 MB of the MiSTer SDRAM.
// sdram.v runs one access (or refresh) per 8 clk64 cycle, started by a rising
// edge on ce / refresh, so every operation here is given 5 clk_sys periods.
wire        xram_req, xram_we;
wire [22:0] xram_addr;
wire  [7:0] xram_din, sdram_dout;
reg   [7:0] xram_dout;
reg         xram_ack;
reg         sd_ce = 0, sd_refresh = 0;

// sdram_sz[15] is set when MiSTer reports the module size; without that
// information just trust the OSD setting
wire sdram_fitted = sdram_sz[15] ? (sdram_sz[2:0] != 0) : 1'b1;
wire xram_present = sdram_fitted && !status[14];

assign SDRAM_CKE = 1;

sdram sdram
(
	.sd_addr(SDRAM_A),
	.sd_data(SDRAM_DQ),
	.sd_ba(SDRAM_BA),
	.sd_cs(SDRAM_nCS),
	.sd_we(SDRAM_nWE),
	.sd_ras(SDRAM_nRAS),
	.sd_cas(SDRAM_nCAS),
	.sd_clk(SDRAM_CLK),
	.sd_dqm({SDRAM_DQMH, SDRAM_DQML}),

	.clk(clk64),
	.init(~pll_locked),
	.refresh(sd_refresh),
	.addr({2'd0, xram_addr}),
	.ce(sd_ce),
	.we(xram_we),
	.din(xram_din),
	.dout(sdram_dout)
);

always @(posedge clk_sys) begin
	reg [1:0] st = 0;          // 0 idle, 1 access, 2 refresh, 3 recover
	reg [2:0] cnt;
	reg [7:0] rf_timer = 0;    // refresh at least every ~8 us (64 ms / 8192 rows)
	reg       rf_due = 0;

	xram_ack <= 0;
	rf_timer <= rf_timer + 1'd1;
	if (&rf_timer) rf_due <= 1;

	case (st)
		0: begin
			cnt <= 0;
			if (rf_due) begin sd_refresh <= 1; rf_due <= 0; st <= 2; end
			else if (xram_req && !xram_ack) begin sd_ce <= 1; st <= 1; end
		end
		1: begin
			cnt <= cnt + 1'd1;
			if (cnt == 4) begin sd_ce <= 0; xram_dout <= sdram_dout; xram_ack <= 1; st <= 3; end
		end
		2: begin
			cnt <= cnt + 1'd1;
			if (cnt == 4) begin sd_refresh <= 0; st <= 3; end
		end
		3: st <= 0;
	endcase

end

// ------------------------------------------------------------------ core
wire        ce_pix;
wire  [3:0] r, g, b;
wire        hsync, vsync, hblank, vblank, field;

// 400 line pictures are sent as two alternating fields; the scaler weaves them
assign VGA_F1 = field;
wire [17:0] audio_l, audio_r;
wire        drive_led;

// joystick_n: [4] fire, [3] up, [2] down, [1] left, [0] right
wire [4:0] joy_a = {joystick_0[4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
wire [4:0] joy_b = {joystick_1[4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};

c65_core core
(
	.clk(clk_sys),
	.reset(reset),
	.ntsc(ntsc),
	.dma_f018b(~status[3]),
	.turbo(status[13:12]),

	.ld_addr(ioctl_addr[16:0]),
	.ld_data(ioctl_dout),
	.ld_wr(rom_download && ioctl_wr && (ioctl_addr[26:17] == 0)),

	.ps2_key(ps2_key),
	.kbd_layout(status[11:10]),
	.joy1(joy_b),
	.joy2(joy_a),
	.ps2_mouse(ps2_mouse),
	.mouse_port(status[16:15] == 2'd0 ? 2'd2 : status[16:15] == 2'd1 ? 2'd1 : 2'd0),

	.ce_pix(ce_pix),
	.r(r), .g(g), .b(b),
	.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
	.field(field),

	.audio_l(audio_l), .audio_r(audio_r),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size[31:0]),
	.sd_lba(sd_lba[0]),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr),
	.drive_led(drive_led),

	.rtc(RTC),

	.xram_present(xram_present),
	.xram_req(xram_req),
	.xram_we(xram_we),
	.xram_addr(xram_addr),
	.xram_din(xram_din),
	.xram_dout(xram_dout),
	.xram_ack(xram_ack),

	.dbg_pc(), .dbg_sync(), .dbg_op(), .dbg_a(), .dbg_x(), .dbg_y(), .dbg_z(), .dbg_b(), .dbg_p(), .dbg_sp()
);

assign AUDIO_L = audio_l[17:2];
assign AUDIO_R = audio_r[17:2];

// ------------------------------------------------------------------ video
// The core produces pixels at clk_sys/2; the mixer runs on clk64 (= 2x clk_sys,
// same PLL) so the scandoubler has room.
assign CLK_VIDEO = clk64;

reg        ce_pix64;
reg  [3:0] r64, g64, b64;
reg        hs64, vs64, hbl64, vbl64;

always @(posedge clk64) begin
	reg ce_d;
	ce_d     <= ce_pix;
	ce_pix64 <= ce_pix & ~ce_d;
	if (ce_pix & ~ce_d) begin
		r64 <= r; g64 <= g; b64 <= b;
		hs64 <= hsync; vs64 <= vsync; hbl64 <= hblank; vbl64 <= vblank;
	end
end

wire [1:0] scale = status[7:6];
wire       scandoubler = (scale != 0) || forced_scandoubler;
assign     VGA_SL = (scale > 1) ? scale - 1'd1 : 2'd0;

video_mixer #(.LINE_LENGTH(1056), .HALF_DEPTH(1), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix64),

	.scandoubler(scandoubler),
	.hq2x(scale == 1),
	.gamma_bus(gamma_bus),

	.R(r64), .G(g64), .B(b64),
	.HSync(hs64), .VSync(vs64), .HBlank(hbl64), .VBlank(vbl64),

	.HDMI_FREEZE(1'b0),
	.freeze_sync(),

	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

endmodule
