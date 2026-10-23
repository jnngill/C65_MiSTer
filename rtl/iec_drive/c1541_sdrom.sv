// One Commodore 1541 on the IEC bus, with its 16K DOS ROM kept outside the
// FPGA (in SDRAM).  Based on c1541_multi by Alexey Melnikov (MiSTer C64 /
// C128 cores), reduced to a single drive, no parallel cable and no RAM
// expansion.  D64 images, and G64 images with gcr_mode set (MiSTer's main
// program converts G64 tracks when the drive asks for 32-block tracks).
//
// The drive CPU latches its data on ph2_f.  Straight after ph2_f the new
// address is sent out as a ROM read (rom_req / rom_ack), and the byte is
// held until the next ph2_f, a full microsecond later; the SDRAM answers in
// well under half of that.  Bytes outside the ROM are not used by the CPU.
//
// clk should be 32 MHz-ish with ce at half of it (the 1541 then runs at 1 MHz).

module c1541_sdrom
(
	input         clk,
	input         reset,
	input         ce,

	input         gcr_mode,         // the mounted image is a G64
	input         img_mounted,
	input         img_readonly,
	input  [31:0] img_size,

	input   [1:0] drive_num,        // device 8 + drive_num
	output        led,

	input         iec_atn_i,        // from the computer, 1 = released
	input         iec_data_i,
	input         iec_clk_i,
	output        iec_data_o,       // to the computer, 1 = released
	output        iec_clk_o,

	// ROM in external memory
	output reg        rom_req,      // held until rom_ack
	output reg [13:0] rom_addr,
	input             rom_ack,
	input       [7:0] rom_q,

	output [31:0] sd_lba,
	output  [5:0] sd_blk_cnt,
	output        sd_rd,
	output        sd_wr,
	input         sd_ack,
	input  [13:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr
);

wire iec_atn, iec_data, iec_clk;
iecdrv_sync atn_sync(clk, iec_atn_i,  iec_atn);
iecdrv_sync dat_sync(clk, iec_data_i, iec_data);
iecdrv_sync clk_sync(clk, iec_clk_i,  iec_clk);

wire reset_drv;
iecdrv_sync rst_sync(clk, reset, reset_drv);

// 1 MHz CPU phases from the 16 MHz ce
reg ph2_r, ph2_f;
always @(posedge clk) begin
	reg [3:0] div;
	ph2_r <= 0;
	ph2_f <= 0;
	if (ce) begin
		div <= div + 1'd1;
		ph2_r <= !div[3] && !div[2:0];
		ph2_f <=  div[3] && !div[2:0];
	end
end

// ROM fetch for the address the CPU puts out after ph2_f
wire [14:0] drv_addr;
reg   [7:0] drv_data;
always @(posedge clk) begin
	reg [1:0] dly;
	if (ph2_f) dly <= 2'd3;
	else if (dly) begin
		dly <= dly - 1'd1;
		if (dly == 2'd1) begin rom_addr <= drv_addr[13:0]; rom_req <= 1'b1; end
	end
	if (rom_req && rom_ack) begin rom_req <= 1'b0; drv_data <= rom_q; end
	if (reset_drv) rom_req <= 1'b0;
end

wire iec_data_d, iec_clk_d;
assign iec_clk_o  = iec_clk_d  | reset_drv;
assign iec_data_o = iec_data_d | reset_drv;

wire led_drv;
assign led = led_drv & ~reset_drv;

c1541_drv c1541_drv
(
	.clk(clk),
	.reset(reset_drv),

	.gcr_mode(gcr_mode),

	.ce(ce),
	.ph2_r(ph2_r),
	.ph2_f(ph2_f),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.drive_num(drive_num),
	.led(led_drv),

	.iec_atn_i(iec_atn),
	.iec_data_i(iec_data & iec_data_o),
	.iec_clk_i(iec_clk & iec_clk_o),
	.iec_data_o(iec_data_d),
	.iec_clk_o(iec_clk_d),

	.par_data_i(8'hFF),
	.par_stb_i(1'b1),
	.par_data_o(),
	.par_stb_o(),

	.ext_en(1'b0),
	.rom_addr(drv_addr),
	.rom_data(drv_data),

	.clk_sys(clk),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

endmodule
