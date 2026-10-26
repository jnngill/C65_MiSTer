// MEGA65 SD card controller, backed by the image mounted in MiSTer slot 3
// ("Mount SD Card / Data File"), and the F011 disk image registers.
//
//   $D680  write: command   $00 / $01 reset (clears errors), $02 read sector,
//                           $03 write sector, $81 map the sector buffer at
//                           $DE00-$DFFF, $82 unmap it; others are ignored
//          read:  status    bit 0 / 1 busy, bit 3 buffer mapped, bit 4 SDHC,
//                           bit 5 / 6 error (no image, or write to a read
//                           only image)
//   $D681-$D684  sector number (512 byte sectors, LSB first)
//   $D68B  F011 image flags: bit 0 drive 0 uses an image on the SD card,
//          bit 1 its media present, bit 2 it is write enabled; bits 3-5 the
//          same for drive 1
//   $D68C-$D68F  drive 0 image: first sector on the SD card
//   $D690-$D693  drive 1 image
//
// Attached images stay attached through a reset, as on a MEGA65; mounting a
// new SD card image detaches both, and mounting a disk on a drive in the OSD
// detaches that drive's.
//
// The sector buffer is the 512 byte RAM at $FFD6E00 in the core; the MiSTer
// moves sectors as two 256 byte blocks (sd_lba counts 256 byte blocks).

module m65_sdc (
	input  logic        clk,
	input  logic        reset,

	input  logic  [7:0] reg_addr,      // $D600 + reg_addr
	input  logic        reg_we,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,
	output logic        reg_sel,       // reg_addr is one of this unit's registers

	output logic        mapped,        // sector buffer visible at $DE00

	output logic        d0_img, d0_ok, d0_wen,
	output logic [31:0] d0_start,
	output logic        d1_img, d1_ok, d1_wen,
	output logic [31:0] d1_start,
	input  logic  [1:0] osd_mounted,   // a disk mounted on drive 0 / 1 in the OSD

	input  logic        img_mounted,   // slot 3
	input  logic        img_readonly,
	input  logic [31:0] img_size,
	input  logic        img_big,       // the image is 4 GB or larger (size bits 63-32)
	output logic        present,
	output logic        ro,
	output logic [31:0] size,

	output logic [31:0] sd_lba,
	output logic        sd_rd,
	output logic        sd_wr,
	input  logic        sd_ack         // slot 3 acknowledge while this unit owns the slot
);

logic [31:0] sector;
logic  [7:0] flags;
logic        busy, err, ack_seen;

assign d0_img   = flags[0];
assign d0_ok    = flags[1];
assign d0_wen   = flags[2];
assign d1_img   = flags[3];
assign d1_ok    = flags[4];
assign d1_wen   = flags[5];
assign reg_sel  = (reg_addr >= 8'h80 && reg_addr <= 8'h84) || (reg_addr >= 8'h8B && reg_addr <= 8'h93);

always_ff @(posedge clk) begin
	if (img_mounted) begin
		present <= (img_size != 32'd0) || img_big;
		ro      <= img_readonly;
		size    <= img_size;
	end

	if (reset) begin
		busy <= 1'b0; err <= 1'b0; mapped <= 1'b0; sd_rd <= 1'b0; sd_wr <= 1'b0; sector <= '0;
	end
	else begin
		if (reg_we) case (reg_addr)
			8'h80: if (!busy) case (reg_din)
				8'h00, 8'h01: err <= 1'b0;
				8'h02, 8'h03: begin
					if (!present || (reg_din[0] && ro)) err <= 1'b1;
					else begin
						err <= 1'b0; busy <= 1'b1; ack_seen <= 1'b0;
						sd_lba <= {sector[30:0], 1'b0};
						if (reg_din[0]) sd_wr <= 1'b1; else sd_rd <= 1'b1;
					end
				end
				8'h81: mapped <= 1'b1;
				8'h82: mapped <= 1'b0;
				default: ;
			endcase
			8'h81: sector[7:0]   <= reg_din;
			8'h82: sector[15:8]  <= reg_din;
			8'h83: sector[23:16] <= reg_din;
			8'h84: sector[31:24] <= reg_din;
			8'h8B: flags <= reg_din;
			8'h8C: d0_start[7:0]   <= reg_din;
			8'h8D: d0_start[15:8]  <= reg_din;
			8'h8E: d0_start[23:16] <= reg_din;
			8'h8F: d0_start[31:24] <= reg_din;
			8'h90: d1_start[7:0]   <= reg_din;
			8'h91: d1_start[15:8]  <= reg_din;
			8'h92: d1_start[23:16] <= reg_din;
			8'h93: d1_start[31:24] <= reg_din;
			default: ;
		endcase

		if (busy) begin
			if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; ack_seen <= 1'b1; end
			else if (ack_seen) busy <= 1'b0;
		end
	end

	// a new card, or a disk chosen in the OSD, replaces the attached images
	if (img_mounted)    flags[5:0] <= '0;
	if (osd_mounted[0]) flags[2:0] <= '0;
	if (osd_mounted[1]) flags[5:3] <= '0;
end

always_comb begin
	reg_dout = 8'h00;
	case (reg_addr)
		8'h80: reg_dout = {1'b0, err, err, 1'b1, mapped, 1'b0, busy, busy};
		8'h81: reg_dout = sector[7:0];
		8'h82: reg_dout = sector[15:8];
		8'h83: reg_dout = sector[23:16];
		8'h84: reg_dout = sector[31:24];
		8'h8B: reg_dout = flags;
		8'h8C: reg_dout = d0_start[7:0];
		8'h8D: reg_dout = d0_start[15:8];
		8'h8E: reg_dout = d0_start[23:16];
		8'h8F: reg_dout = d0_start[31:24];
		8'h90: reg_dout = d1_start[7:0];
		8'h91: reg_dout = d1_start[15:8];
		8'h92: reg_dout = d1_start[23:16];
		8'h93: reg_dout = d1_start[31:24];
		default: ;
	endcase
end

endmodule
