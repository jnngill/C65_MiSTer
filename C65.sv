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
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SCALER     = 0;
assign VGA_DISABLE    = 0;
assign HDMI_FREEZE    = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = drive_led | drv_led | ioctl_download;
assign BUTTONS   = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[9:8];

wire [1:0] ar = status[5:4];
assign VIDEO_ARX = (!ar) ? 13'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 13'd3 : 13'd0;

`include "build_id.v"
localparam CONF_STR = {
	"C65;UART38400:19200:9600:4800:2400:1200:300;",
	"S0,D81,Mount Drive 8;",
	"S1,D81,Mount Drive 9 (1565);",
	"S2,D64G64,Mount Drive 10 (1541);",
	"S3,IMGSCPBINDAT,Mount SD Card / Data File (MEGA65);",
	"F1,ROMBIN,Load System ROM;",
	"F2,PRG,Load Program;",
	"F3,ROMBIN,Load 1541 ROM;",
	"-;",
	"O[2],Video Standard,PAL,NTSC;",
	"O[5:4],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[7:6],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
	"O[9:8],Stereo Mix,None,25%,50%,100%;",
	"O[11:10],Keyboard Layout,US,UK,DE,Positional;",
	"O[13:12],CPU Speed,3.5 MHz,8 MHz,16 MHz;",
	"O[14],Expansion RAM,4MB (needs SDRAM),Off;",
	"O[16:15],Mouse,Port 2,Port 1,Off;",
	"O[3],DMA Revision,F018B,F018A;",
	"O[17],MEGA65 Extensions,Off,On;",
	"O[18],GO64,C64 mode,Load C64 core;",
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
wire         ioctl_wait;

wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire  [15:0] sdram_sz;
wire  [24:0] ps2_mouse;
wire  [64:0] RTC;

wire  [31:0] sd_lba[4];
wire   [3:0] sd_rd, sd_wr, sd_ack;
wire   [5:0] sd_blk_cnt[4];
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[4];
wire         sd_buff_wr;
wire   [3:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(4), .BLKSZ(1)) hps_io
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
	.ioctl_wait(ioctl_wait),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
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
// boot.rom arrives as index 0, boot1.rom as $40; OSD files as n plus the
// extension number in bits 7:6 (ROM / BIN)
wire rom_download = ioctl_download && (ioctl_index == 16'd0 || ioctl_index[5:0] == 6'd1);
wire prg_download = ioctl_download && (ioctl_index[5:0] == 6'd2);
wire drv_download = ioctl_download && (ioctl_index == 16'h0040 || ioctl_index[5:0] == 6'd3);


reg  rom_loaded = 0;
reg  reset;

always @(posedge clk_sys) begin
	reg [19:0] reset_cnt = '1;
	reg        m65_ext_d;

	if (rom_download && ioctl_wr) rom_loaded <= 1;

	m65_ext_d <= status[17];

	// changing the MEGA65 Extensions option restarts the machine
	if (RESET | status[0] | buttons[1] | !pll_locked | rom_download | !rom_loaded | (m65_ext_d != status[17])) reset_cnt <= '1;
	else if (reset_cnt != 0) reset_cnt <= reset_cnt - 1'd1;

	reset <= (reset_cnt != 0);
end

// ------------------------------------------------------------------ SDRAM module
// The C65's expansion RAM (banks 6-15 and the 4 MB DMA region) lives in the
// first 8 MB of the MiSTer SDRAM, the MEGA65 attic RAM in the next 8 MB, the
// 1541's 16K DOS ROM at 16 MB and a copy of the 128K C65 ROM at 17 MB (put
// back after a MEGA65 program has used $20000-$3FFFF as RAM).
// sdram.v runs one access (or refresh) per 8 clk64 cycle, started by a rising
// edge on ce / refresh, so every operation here is given 5 clk_sys periods.
// Priority: 1541 ROM reads (the drive needs its byte within 1 us), refresh,
// the ROM downloads, the C65 ROM restore, then the C65.
wire        xram_req, xram_we;
wire [23:0] xram_addr;
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
	.addr(sd_a),
	.ce(sd_ce),
	.we(sd_we_r),
	.din(sd_d),
	.dout(sdram_dout)
);

reg  [24:0] sd_a;
reg         sd_we_r;
reg   [7:0] sd_d;

// 1541 ROM: read port for the drive, write port for the download
wire        drv_rom_req;
wire [13:0] drv_rom_addr;
reg         drv_rom_ack = 0;
reg   [7:0] drv_rom_q;
reg         romw_pend = 0;
reg  [24:0] romw_addr;
reg   [7:0] romw_data;
reg         drv_rom_ok = 0;      // a 1541 ROM has been loaded
reg         c65_rom_ok = 0;      // the SDRAM holds a copy of the C65 ROM
assign      ioctl_wait = (drv_download || rom_download) && romw_pend;

// C65 ROM restore reads
wire        rrom_req;
wire [16:0] rrom_addr;
reg         rrom_ack = 0;
reg   [7:0] rrom_q;

always @(posedge clk_sys) begin
	reg [1:0] st = 0;          // 0 idle, 1 access, 2 refresh, 3 recover
	reg [1:0] owner;           // 0 C65 ROM restore read, 1 C65, 2 1541 ROM read, 3 ROM download write
	reg [2:0] cnt;
	reg [7:0] rf_timer = 0;    // refresh at least every ~8 us (64 ms / 8192 rows)
	reg       rf_due = 0;
	reg       drv_was = 0;
	reg       rom_was = 0;

	xram_ack    <= 0;
	drv_rom_ack <= 0;
	rrom_ack    <= 0;
	rf_timer <= rf_timer + 1'd1;
	if (&rf_timer) rf_due <= 1;

	// 1541 ROM download: one SDRAM write per byte, the download waits meanwhile
	drv_was <= drv_download;
	if (drv_download && ioctl_wr) begin
		romw_pend <= 1; romw_addr <= {11'h400, ioctl_addr[13:0]}; romw_data <= ioctl_dout;
		drv_rom_ok <= 0;
	end
	if (drv_was && !drv_download) drv_rom_ok <= 1;
	// the C65 ROM goes to its block RAM (in the core) and to SDRAM
	rom_was <= rom_download;
	if (rom_download && ioctl_wr && ioctl_addr[26:17] == 0) begin
		romw_pend <= 1; romw_addr <= {8'h88, ioctl_addr[16:0]}; romw_data <= ioctl_dout;
		c65_rom_ok <= 0;
	end
	if (rom_was && !rom_download) c65_rom_ok <= sdram_fitted;

	case (st)
		0: begin
			cnt <= 0;
			if (drv_rom_req && !drv_rom_ack) begin
				sd_a <= {11'h400, drv_rom_addr}; sd_we_r <= 0; owner <= 2'd2; sd_ce <= 1; st <= 1;
			end
			else if (rf_due) begin sd_refresh <= 1; rf_due <= 0; st <= 2; end
			else if (romw_pend) begin
				sd_a <= romw_addr; sd_we_r <= 1; sd_d <= romw_data; owner <= 2'd3; sd_ce <= 1; st <= 1;
			end
			else if (rrom_req && !rrom_ack) begin
				sd_a <= {8'h88, rrom_addr}; sd_we_r <= 0; owner <= 2'd0; sd_ce <= 1; st <= 1;
			end
			else if (xram_req && !xram_ack) begin
				sd_a <= {1'b0, xram_addr}; sd_we_r <= xram_we; sd_d <= xram_din; owner <= 2'd1; sd_ce <= 1; st <= 1;
			end
		end
		1: begin
			cnt <= cnt + 1'd1;
			if (cnt == 4) begin
				sd_ce <= 0; st <= 3;
				case (owner)
					2'd1: begin xram_dout <= sdram_dout; xram_ack <= 1; end
					2'd2: begin drv_rom_q <= sdram_dout; drv_rom_ack <= 1; end
					2'd0: begin rrom_q <= sdram_dout; rrom_ack <= 1; end
					default: romw_pend <= 0;
				endcase
			end
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
wire  [7:0] r, g, b;
wire        hsync, vsync, hblank, vblank, field;

// 400 line pictures are sent as two alternating fields; the scaler weaves them
assign VGA_F1 = field;
wire [17:0] audio_l, audio_r;
wire        drive_led;

// ------------------------------------------------------------------ core switch
// GO64 / GO128 (core_req from the core) can load the MiSTer C64 or C128 core.
// A core cannot ask the MiSTer for another core, so the request goes into DDR
// at ARM address 0x3FFFF800 ("C65GO", the target 64 / 128, a sequence number),
// where scripts/mister/c65_core_switch.sh, running on the MiSTer, picks it up
// and loads the core.
wire [1:0] core_req;
reg        req_we = 1'b0;
reg  [7:0] req_tgt, req_seq = 8'd0;

assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR     = 29'h7FFFF00;
assign DDRAM_BE       = 8'hFF;
assign DDRAM_RD       = 1'b0;
assign DDRAM_WE       = req_we;
assign DDRAM_DIN      = {8'h00, req_seq, req_tgt, "O", "G", "5", "6", "C"};

always @(posedge clk_sys) begin
	if (req_we && !DDRAM_BUSY) req_we <= 1'b0;
	if (core_req != 2'd0 && !req_we) begin
		req_tgt <= (core_req == 2'd1) ? 8'd64 : 8'd128;
		req_seq <= req_seq + 1'd1;
		req_we  <= 1'b1;
	end
end

// joystick_n: [4] fire, [3] up, [2] down, [1] left, [0] right
wire [4:0] joy_a = {joystick_0[4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
wire [4:0] joy_b = {joystick_1[4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};

// the two F011 drives share the controller's one transfer: same address, same data
assign sd_lba[1] = sd_lba[0];
assign sd_buff_din[1] = sd_buff_din[0];
assign sd_blk_cnt[0] = 6'd1;     // the F011 moves 512 byte sectors: two 256 byte blocks
assign sd_blk_cnt[1] = 6'd1;
// slot 3: the MEGA65 SD card (a FAT32 image, or a single data file), 512 bytes at a time
assign sd_blk_cnt[3] = 6'd1;

// ------------------------------------------------------------------ 1541 on the IEC bus
// Unit 10 (8 is the internal drive, 9 the 1565).  Held in reset until a 1541
// ROM has been loaded (boot1.rom or OSD), which needs the SDRAM module.
wire iec_atn, iec_clk, iec_data;          // the C65's side, 1 = released
wire drv_iec_clk, drv_iec_data;
wire drv_led;
reg  drv_ce = 0;
always @(posedge clk_sys) drv_ce <= ~drv_ce;

// at mount time ioctl_index[7:6] is the extension: 0 = .D64, 1 = .G64
reg  drv_gcr = 0;
always @(posedge clk_sys) if (img_mounted[2]) drv_gcr <= (ioctl_index[7:6] == 2'd1);

c1541_sdrom drive1541
(
	.clk(clk_sys),
	.reset(reset | ~drv_rom_ok | ~sdram_fitted),
	.ce(drv_ce),
	.gcr_mode(drv_gcr),

	.img_mounted(img_mounted[2]),
	.img_readonly(img_readonly),
	.img_size(img_size[31:0]),

	.drive_num(2'd2),
	.led(drv_led),

	.iec_atn_i(iec_atn),
	.iec_data_i(iec_data),
	.iec_clk_i(iec_clk),
	.iec_data_o(drv_iec_data),
	.iec_clk_o(drv_iec_clk),

	.rom_req(drv_rom_req),
	.rom_addr(drv_rom_addr),
	.rom_ack(drv_rom_ack),
	.rom_q(drv_rom_q),

	.sd_lba(sd_lba[2]),
	.sd_blk_cnt(sd_blk_cnt[2]),
	.sd_rd(sd_rd[2]),
	.sd_wr(sd_wr[2]),
	.sd_ack(sd_ack[2]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[2]),
	.sd_buff_wr(sd_buff_wr)
);

c65_core core
(
	.clk(clk_sys),
	.reset_in(reset),
	.ntsc(ntsc),
	.dma_f018b(~status[3]),
	.turbo(status[13:12]),

	.ld_addr(ioctl_addr[16:0]),
	.ld_data(ioctl_dout),
	.ld_wr(rom_download && ioctl_wr && (ioctl_addr[26:17] == 0)),
	.rom_backup(c65_rom_ok), .rrom_req(rrom_req), .rrom_addr(rrom_addr), .rrom_q(rrom_q), .rrom_ack(rrom_ack),
	.prg_dl(prg_download), .prg_wr(prg_download && ioctl_wr), .prg_ofs(ioctl_addr[15:0]), .prg_byte(ioctl_dout),

	.ps2_key(ps2_key),
	.kbd_layout(status[11:10]),
	.joy1(joy_b),
	.joy2(joy_a),
	.ps2_mouse(ps2_mouse),
	.mouse_port(status[16:15] == 2'd0 ? 2'd2 : status[16:15] == 2'd1 ? 2'd1 : 2'd0),
	.m65_ext(status[17]),
	.iec_atn_o(iec_atn), .iec_clk_o(iec_clk), .iec_data_o(iec_data),
	.iec_clk_i(drv_iec_clk), .iec_data_i(drv_iec_data),
	.sd3_mounted(img_mounted[3]), .sd3_lba(sd_lba[3]), .sd3_rd(sd_rd[3]), .sd3_wr(sd_wr[3]), .sd3_ack(sd_ack[3]),
	.sd3_buff_din(sd_buff_din[3]), .sd3_big(|img_size[63:32]),
	.go64_core(status[18]), .core_req(core_req),
	.uart_rxd(UART_RXD),
	.uart_txd(UART_TXD),

	.ce_pix(ce_pix),
	.r(r), .g(g), .b(b),
	.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
	.field(field),

	.audio_l(audio_l), .audio_r(audio_r),

	.img_mounted(img_mounted[1:0]),
	.img_readonly(img_readonly),
	.img_size(img_size[31:0]),
	.sd_lba(sd_lba[0]),
	.sd_rd(sd_rd[1:0]),
	.sd_wr(sd_wr[1:0]),
	.sd_ack(sd_ack[1:0]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[0]),
	.sd_buff_wr(sd_buff_wr),
	.drive_led(drive_led),

	.rtc(RTC),

	.xram_present(xram_present),
	.attic_present(sdram_fitted),
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
reg  [7:0] r64, g64, b64;
reg        hs64, vs64, hbl64, vbl64;

// ce_pix marks each new pixel (every second clk_sys, or every clk_sys in the
// 1280 pixel modes).  A toggle carries it to clk64, which samples each level.
reg pix_tg = 0;
always @(posedge clk_sys) if (ce_pix) pix_tg <= ~pix_tg;

always @(posedge clk64) begin
	reg tg_d;
	tg_d     <= pix_tg;
	ce_pix64 <= (pix_tg != tg_d);
	if (pix_tg != tg_d) begin
		r64 <= r; g64 <= g; b64 <= b;
		hs64 <= hsync; vs64 <= vsync; hbl64 <= hblank; vbl64 <= vblank;
	end
end

wire [1:0] scale = status[7:6];
wire       scandoubler = (scale != 0) || forced_scandoubler;
assign     VGA_SL = scale;

video_mixer #(.LINE_LENGTH(1056), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix64),

	.scandoubler(scandoubler),
	.hq2x(1'b0),                    // HQ2x is not built (see sys/scandoubler.v)
	.gamma_bus(gamma_bus),

	.R(r64), .G(g64), .B(b64),
	.HSync(hs64), .VSync(vs64), .HBlank(hbl64), .VBlank(vbl64),

	.HDMI_FREEZE(1'b0),
	.freeze_sync(),

	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

endmodule
