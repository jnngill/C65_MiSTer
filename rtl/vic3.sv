// CSG 4567 "VIC-III" for the C65 MiSTer core.
//
// Line-based implementation (no cycle-exact VIC-II bad lines / sprite DMA):
//   * VIC-II text / bitmap modes, 40 and 80 columns, C65 character attributes
//   * bitplane modes (up to 8 planes, 320 or 640 wide)
//   * 8 sprites with collisions
//   * 256 entry palette (4 bits per gun), raster interrupt
//
// clk is the system clock (32x the 1 MHz phase clock); one 640-mode pixel is
// two clk periods (ce_pix), one 320-mode pixel is four.

module vic3 (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_pix,        // 640-mode pixel enable (clk/2)
	input  logic        ntsc,

	// register interface (strobes are one clk wide)
	input  logic        vic3_mode,     // $D02F key state: registers >= $30 visible
	input  logic        vic4_mode,     // MEGA65 key: the few VIC-IV registers we model are visible
	input  logic  [6:0] reg_addr,
	input  logic        reg_we,
	input  logic        reg_re,        // read strobe (clears collision latches)
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,
	input  logic  [9:0] pal_addr,      // $D100-$D3FF as {gun, index}; gun 1=R 2=G 3=B
	input  logic        pal_we,
	output logic  [7:0] pal_dout,

	// control outputs to the system
	output logic  [7:0] ctrl_a,        // $D030
	output logic  [7:0] ctrl_b,        // $D031
	output logic        irq_n,

	// video memory: RAM ($00000-$5FFFF) and ROM share the address, 1 clk latency
	input  logic  [1:0] vic_bank,      // from CIA2 (already inverted: 0 = $0000)
	output logic [18:0] vaddr,
	input  logic  [7:0] vram_q,
	input  logic  [7:0] vrom_q,

	output logic  [3:0] r, g, b,
	output logic        hsync, vsync, hblank, vblank,
	output logic        field,         // 400-line (interlaced) modes: 0 = first field, 1 = second
	output logic  [8:0] raster
);

// ------------------------------------------------------------------ registers
logic [8:0] spr_x [8];
logic [7:0] spr_y [8];
logic [7:0] spr_en, spr_xexp, spr_yexp, spr_mc, spr_pri;
logic [7:0] spr_col [8];
logic [7:0] spr_mc0, spr_mc1;
logic [7:0] ss_coll, sd_coll;
logic [2:0] yscroll, xscroll;
logic       rsel, den, bmm, ecm, csel, mcm, res;
logic [8:0] rcmp;
logic [3:0] vm, cb;
logic [3:0] irq_flag, irq_en;
logic [7:0] col_border, col_bg0, col_bg1, col_bg2, col_bg3;
logic [7:0] bp_en, bp_comp, bpx, bpy, hpos, vpos;
logic [7:0] bp_addr [8];
logic [22:0] sprptr_adr;     // VIC-IV $D06C-$D06E: sprite pointer list address
logic        sprptr16;       // VIC-IV $D06E.7: 16-bit sprite pointers
logic  [2:0] bp_bank;        // VIC-IV $D07C.0-2: bitplane address bits 19-17
logic  [7:0] ctrl_c;         // VIC-IV $D054: [0] CHR16, [1] FCLRLO, [2] FCLRHI
logic  [7:0] spr16;          // VIC-IV $D06B: 16-colour sprites (16 pixels wide, 4 bits per pixel)
logic  [7:0] sprx64;         // VIC-IV $D057: 64 pixel wide sprites
logic  [7:0] sprhgten;       // VIC-IV $D055: sprite uses the height in $D056
logic  [7:0] sprhght;        // VIC-IV $D056: sprite height in rows
logic  [9:0] linestep;       // VIC-IV $D058/59: bytes from one text row to the next
logic [19:0] scrnptr;        // VIC-IV $D060-63: screen memory address
logic [15:0] colptr;         // VIC-IV $D064/65: offset into colour RAM
logic        hot_reload;     // a VIC-II/III register changed: recompute the pointers above
logic  [1:0] vic_bank_d;

wire h640  = ctrl_b[7];
wire [6:0]  n_cols   = h640 ? 7'd80 : 7'd40;
// VIC-II screen address inside the 16-bit video bank
wire [15:0] scr_base = h640 ? {vic_bank, vm[3:1], 11'd0} : {vic_bank, vm, 10'd0};
wire chr16  = ctrl_c[0] && vic4_mode;     // 16-bit character numbers: two bytes per screen and colour cell
wire fclrlo = ctrl_c[1];                  // full colour for characters $000-$0FF
wire fclrhi = ctrl_c[2];                  // full colour for characters $100 and up
wire attr  = ctrl_b[5];
wire bpm   = ctrl_b[4];
wire v400  = ctrl_b[3];
wire palram = ctrl_a[2];
wire crom9 = ctrl_a[6];

logic [8:0] vc;           // raster line
logic       ss_set_any, sd_set_any;
logic [7:0] ss_set, sd_set;
logic       irq_raster_set;

always_ff @(posedge clk) begin
	if (reset) begin
		spr_en <= '0; spr_xexp <= '0; spr_yexp <= '0; spr_mc <= '0; spr_pri <= '0;
		yscroll <= 3'd3; xscroll <= '0; rsel <= 1'b1; den <= 1'b0; bmm <= '0; ecm <= '0;
		csel <= 1'b1; mcm <= '0; res <= '0; rcmp <= '0; vm <= 4'd1; cb <= 4'd2;
		irq_flag <= '0; irq_en <= '0;
		col_border <= 8'd14; col_bg0 <= 8'd6; col_bg1 <= 8'd1; col_bg2 <= 8'd2; col_bg3 <= 8'd3;
		spr_mc0 <= 8'd4; spr_mc1 <= 8'd0;
		ctrl_a <= '0; ctrl_b <= '0;
		bp_en <= '0; bp_comp <= '0; bpx <= '0; bpy <= '0; hpos <= '0; vpos <= '0;
		ss_coll <= '0; sd_coll <= '0;
		sprptr_adr <= '0; sprptr16 <= 1'b0; bp_bank <= '0;
		spr16 <= '0; sprx64 <= '0; sprhgten <= '0; sprhght <= 8'd21;
		ctrl_c <= '0; linestep <= 10'd40; scrnptr <= '0; colptr <= '0; hot_reload <= 1'b1; vic_bank_d <= '0;
		for (int i = 0; i < 8; i++) begin
			spr_x[i] <= '0; spr_y[i] <= '0; spr_col[i] <= '0; bp_addr[i] <= '0;
		end
	end
	else begin
		// collision / raster event latches
		if (ss_set_any) begin
			if (ss_coll == 8'd0) irq_flag[2] <= 1'b1;
			ss_coll <= ss_coll | ss_set;
		end
		if (sd_set_any) begin
			if (sd_coll == 8'd0) irq_flag[1] <= 1'b1;
			sd_coll <= sd_coll | sd_set;
		end
		if (irq_raster_set) irq_flag[0] <= 1'b1;

		// "hot registers": like the VIC-IV, writing a VIC-II/III register that
		// moves or resizes the screen reloads the extended pointers from it
		hot_reload <= 1'b0;
		vic_bank_d <= vic_bank;
		if (vic_bank_d != vic_bank) hot_reload <= 1'b1;
		if (hot_reload) begin
			scrnptr  <= {4'd0, scr_base};
			linestep <= {3'd0, n_cols};
			colptr   <= '0;
		end
		if (reg_we && (reg_addr == 7'h16 || reg_addr == 7'h18 || (vic3_mode && reg_addr == 7'h31)))
			hot_reload <= 1'b1;

		if (reg_re) begin
			if (reg_addr == 7'h1E) ss_coll <= '0;
			if (reg_addr == 7'h1F) sd_coll <= '0;
		end

		if (reg_we) begin
			casez (reg_addr)
				7'b000_????: begin
					if (reg_addr[0]) spr_y[reg_addr[3:1]] <= reg_din;
					else             spr_x[reg_addr[3:1]][7:0] <= reg_din;
				end
				7'h10: for (int i = 0; i < 8; i++) spr_x[i][8] <= reg_din[i];
				7'h11: begin rcmp[8] <= reg_din[7]; ecm <= reg_din[6]; bmm <= reg_din[5];
				             den <= reg_din[4]; rsel <= reg_din[3]; yscroll <= reg_din[2:0]; end
				7'h12: rcmp[7:0] <= reg_din;
				7'h15: spr_en <= reg_din;
				7'h16: begin res <= reg_din[5]; mcm <= reg_din[4]; csel <= reg_din[3]; xscroll <= reg_din[2:0]; end
				7'h17: spr_yexp <= reg_din;
				7'h18: begin vm <= reg_din[7:4]; cb <= reg_din[3:0]; end
				7'h19: irq_flag <= irq_flag & ~reg_din[3:0];
				7'h1A: irq_en <= reg_din[3:0];
				7'h1B: spr_pri <= reg_din;
				7'h1C: spr_mc <= reg_din;
				7'h1D: spr_xexp <= reg_din;
				7'h20: col_border <= reg_din;
				7'h21: col_bg0 <= reg_din;
				7'h22: col_bg1 <= reg_din;
				7'h23: col_bg2 <= reg_din;
				7'h24: col_bg3 <= reg_din;
				7'h25: spr_mc0 <= reg_din;
				7'h26: spr_mc1 <= reg_din;
				7'b010_0111, 7'b010_1???: if (reg_addr <= 7'h2E) spr_col[reg_addr[3:0] - 4'd7] <= reg_din;
				default: ;
			endcase
			if (vic3_mode) begin
				case (reg_addr)
					7'h30: ctrl_a <= reg_din;
					7'h31: ctrl_b <= reg_din;
					7'h32: bp_en <= reg_din;
					7'h33, 7'h34, 7'h35, 7'h36, 7'h37, 7'h38, 7'h39, 7'h3A:
						bp_addr[reg_addr[3:0] - 4'd3] <= reg_din;
					7'h3B: bp_comp <= reg_din;
					7'h3C: bpx <= reg_din;
					7'h3D: bpy <= reg_din;
					7'h3E: hpos <= reg_din;
					7'h3F: vpos <= reg_din;
					default: ;
				endcase
			end
			if (vic4_mode) begin
				case (reg_addr)
					7'h6C: sprptr_adr[7:0]  <= reg_din;
					7'h6D: sprptr_adr[15:8] <= reg_din;
					7'h6E: begin sprptr_adr[22:16] <= reg_din[6:0]; sprptr16 <= reg_din[7]; end
					7'h7C: bp_bank <= reg_din[2:0];
					7'h54: ctrl_c <= reg_din;
					7'h55: sprhgten <= reg_din;
					7'h56: sprhght  <= reg_din;
					7'h57: sprx64   <= reg_din;
					7'h6B: spr16    <= reg_din;
					7'h58: linestep[7:0] <= reg_din;
					7'h59: linestep[9:8] <= reg_din[1:0];
					7'h60: scrnptr[7:0]   <= reg_din;
					7'h61: scrnptr[15:8]  <= reg_din;
					7'h62: scrnptr[19:16] <= reg_din[3:0];
					7'h64: colptr[7:0]  <= reg_din;
					7'h65: colptr[15:8] <= reg_din;
					default: ;
				endcase
			end
		end
	end
end

wire [7:0] cmask = vic3_mode ? 8'h00 : 8'hF0;   // VIC-II mode: 4 bit colour registers

always_comb begin
	reg_dout = 8'hFF;
	casez (reg_addr)
		7'b000_????: reg_dout = reg_addr[0] ? spr_y[reg_addr[3:1]] : spr_x[reg_addr[3:1]][7:0];
		7'h10: for (int i = 0; i < 8; i++) reg_dout[i] = spr_x[i][8];
		7'h11: reg_dout = {vc[8], ecm, bmm, den, rsel, yscroll};
		7'h12: reg_dout = vc[7:0];
		7'h13, 7'h14: reg_dout = 8'h00;
		7'h15: reg_dout = spr_en;
		7'h16: reg_dout = {2'b11, res, mcm, csel, xscroll};
		7'h17: reg_dout = spr_yexp;
		7'h18: reg_dout = {vm, cb[3:1], 1'b1};
		7'h19: reg_dout = {~irq_n, 3'b111, irq_flag};
		7'h1A: reg_dout = {4'hF, irq_en};
		7'h1B: reg_dout = spr_pri;
		7'h1C: reg_dout = spr_mc;
		7'h1D: reg_dout = spr_xexp;
		7'h1E: reg_dout = ss_coll;
		7'h1F: reg_dout = sd_coll;
		7'h20: reg_dout = col_border | cmask;
		7'h21: reg_dout = col_bg0 | cmask;
		7'h22: reg_dout = col_bg1 | cmask;
		7'h23: reg_dout = col_bg2 | cmask;
		7'h24: reg_dout = col_bg3 | cmask;
		7'h25: reg_dout = spr_mc0 | cmask;
		7'h26: reg_dout = spr_mc1 | cmask;
		7'b010_0111, 7'b010_1???: if (reg_addr <= 7'h2E) reg_dout = spr_col[reg_addr[3:0] - 4'd7] | cmask;
		default: ;
	endcase
	if (vic3_mode) begin
		case (reg_addr)
			7'h30: reg_dout = ctrl_a;
			7'h31: reg_dout = ctrl_b;
			7'h32: reg_dout = bp_en;
			7'h33, 7'h34, 7'h35, 7'h36, 7'h37, 7'h38, 7'h39, 7'h3A:
				reg_dout = bp_addr[reg_addr[3:0] - 4'd3];
			7'h3B: reg_dout = bp_comp;
			7'h3C: reg_dout = bpx;
			7'h3D: reg_dout = bpy;
			7'h3E: reg_dout = hpos;
			7'h3F: reg_dout = vpos;
			default: ;
		endcase
	end
	if (vic4_mode) begin
		if (reg_addr >= 7'h40) reg_dout = 8'h00;
		case (reg_addr)
			7'h7C: reg_dout = {5'd0, bp_bank};
			7'h54: reg_dout = ctrl_c;
			7'h55: reg_dout = sprhgten;
			7'h56: reg_dout = sprhght;
			7'h57: reg_dout = sprx64;
			7'h6B: reg_dout = spr16;
			7'h58: reg_dout = linestep[7:0];
			7'h59: reg_dout = {6'd0, linestep[9:8]};
			7'h5E: reg_dout = {1'b0, n_cols};
			7'h60: reg_dout = scrnptr[7:0];
			7'h61: reg_dout = scrnptr[15:8];
			7'h62: reg_dout = {4'd0, scrnptr[19:16]};
			7'h64: reg_dout = colptr[7:0];
			7'h65: reg_dout = colptr[15:8];
			7'h6C: reg_dout = sprptr_adr[7:0];
			7'h6D: reg_dout = sprptr_adr[15:8];
			7'h6E: reg_dout = {sprptr16, sprptr_adr[22:16]};
			default: ;
		endcase
	end
end

assign irq_n  = ~|(irq_flag & irq_en);
assign raster = vc;

// ------------------------------------------------------------------ palette
logic [4:0] pal_r [256];
logic [3:0] pal_g [256];
logic [3:0] pal_b [256];
logic [7:0] pix_idx;        // palette index of the pixel being produced
logic [4:0] pr_q;
logic [3:0] pg_q, pb_q;
logic [4:0] cr_q;
logic [3:0] cg_q, cb_q;

always_ff @(posedge clk) begin
	if (pal_we) begin
		case (pal_addr[9:8])
			2'd1: pal_r[pal_addr[7:0]] <= reg_din[4:0];
			2'd2: pal_g[pal_addr[7:0]] <= reg_din[3:0];
			2'd3: pal_b[pal_addr[7:0]] <= reg_din[3:0];
			default: ;
		endcase
	end
	cr_q <= pal_r[pal_addr[7:0]];
	cg_q <= pal_g[pal_addr[7:0]];
	cb_q <= pal_b[pal_addr[7:0]];
	pr_q <= pal_r[pix_idx];
	pg_q <= pal_g[pix_idx];
	pb_q <= pal_b[pix_idx];
end

always_comb begin
	case (pal_addr[9:8])
		2'd1:    pal_dout = {3'b000, cr_q};
		2'd2:    pal_dout = {4'h0, cg_q};
		default: pal_dout = {4'h0, cb_q};
	endcase
end

// fixed palette ROM for colours 0-15 (used unless $D030.2 selects palette RAM)
function automatic [11:0] rom_pal(input logic [3:0] i);
	case (i)
		4'd0:  rom_pal = 12'h000;
		4'd1:  rom_pal = 12'hFFF;
		4'd2:  rom_pal = 12'hF00;
		4'd3:  rom_pal = 12'h0FF;
		4'd4:  rom_pal = 12'hF0F;
		4'd5:  rom_pal = 12'h0F0;
		4'd6:  rom_pal = 12'h00F;
		4'd7:  rom_pal = 12'hFF0;
		4'd8:  rom_pal = 12'hF60;
		4'd9:  rom_pal = 12'hA40;
		4'd10: rom_pal = 12'hF77;
		4'd11: rom_pal = 12'h555;
		4'd12: rom_pal = 12'h888;
		4'd13: rom_pal = 12'h9F9;
		4'd14: rom_pal = 12'h99F;
		4'd15: rom_pal = 12'hBBB;
	endcase
endfunction

// ------------------------------------------------------------------ timing
// hx counts 640-mode pixels; x = hx[10:1] is the VIC-II sprite X coordinate.
localparam int X_DISP0   = 24;    // first display column (CSEL=1)
localparam int X_BLANK0  = 392;   // start of horizontal blanking / next raster line
localparam int X_HS0     = 416;
localparam int X_HS1     = 448;

wire [9:0] htotal   = ntsc ? 10'd520 : 10'd504;
wire [8:0] vtotal   = ntsc ? 9'd263 : 9'd312;
wire [9:0] x_blank1 = htotal - 10'd24;

logic [10:0] hx;
wire   [9:0] x = hx[10:1];
logic  [5:0] frame;

wire line_start = ce_pix && (hx == {10'(X_BLANK0), 1'b0});   // vc increments here

always_ff @(posedge clk) begin
	irq_raster_set <= 1'b0;
	if (reset) begin
		hx <= '0; vc <= '0; frame <= '0; field <= 1'b0;
	end
	else if (ce_pix) begin
		hx <= (hx == {htotal, 1'b0} - 11'd1) ? 11'd0 : hx + 11'd1;
		if (line_start) begin
			if (vc == vtotal - 9'd1) begin
				vc    <= '0;
				frame <= frame + 6'd1;
				// V400 / INT: the two fields of a 400 line picture alternate frame by frame
				field <= (v400 || ctrl_b[0]) ? ~field : 1'b0;
			end
			else vc <= vc + 9'd1;
		end
		// raster compare one pixel after the line counter changed
		if (hx == {10'(X_BLANK0), 1'b1} && vc == rcmp) irq_raster_set <= 1'b1;
	end
end

// blanking / sync (registered together with the pixel)
logic hbl_i, vbl_i, hs_i, vs_i;
always_comb begin
	hbl_i = (x >= 10'(X_BLANK0)) && (x < x_blank1);
	hs_i  = (x >= 10'(X_HS0)) && (x < 10'(X_HS1));
	if (ntsc) begin
		vbl_i = (vc >= 9'd13) && (vc < 9'd34);
		vs_i  = (vc >= 9'd17) && (vc < 9'd20);
	end else begin
		vbl_i = (vc >= 9'd300) || (vc < 9'd16);
		vs_i  = (vc >= 9'd304) && (vc < 9'd307);
	end
end

// ------------------------------------------------------------------ display window
wire [8:0] y_first = 9'd48 + {6'd0, yscroll};
wire [8:0] dy      = vc - y_first;                 // line within the 200 line window
wire       in_rows = (vc >= y_first) && (dy < 9'd200);
wire       vborder = !den || (rsel ? !(vc >= 9'd51 && vc < 9'd251) : !(vc >= 9'd55 && vc < 9'd247));
wire       hborder = csel ? !(x >= 10'd24 && x < 10'd344) : !(x >= 10'd31 && x < 10'd335);

// cell geometry in 640-mode pixels
wire [4:0] cell_w   = h640 ? 5'd8 : 5'd16;
// first displayed pixel.  40 column modes scroll in 320-pixels; in 80 column
// modes the normal position is XSCROLL = 1 and one step is one 640-pixel.
wire [10:0] gfx_x0  = h640 ? 11'd47 + {8'd0, xscroll} : 11'd48 + {7'd0, xscroll, 1'b0};
wire [10:0] fetch_x0 = gfx_x0 - {6'd0, cell_w};              // fetch runs one cell ahead

// ------------------------------------------------------------------ fetch engine
logic  [6:0] f_col;          // column being fetched
logic  [4:0] f_cnt;          // 640-pixel counter inside the fetch cell
logic        f_run;
logic  [3:0] f_step;         // clk step inside the cell
logic        f_go;
logic [11:0] row_base;       // row * columns
logic  [7:0] f_scr, f_col_byte, f_gfx;
logic  [7:0] f_bp [8];
logic [18:0] vaddr_gfx;

wire [4:0] text_row  = dy[7:3];
wire [2:0] text_rc   = dy[2:0];
wire [11:0] cell_idx = row_base + {5'd0, f_col};

// screen and colour RAM addresses of the cell being fetched
logic [11:0] row_ofs;        // bytes from the start of the screen to this text row
wire  [7:0]  col_ofs  = chr16 ? {f_col, 1'b0} : {1'b0, f_col};
wire [18:0]  scr_addr = scrnptr[18:0] + {7'd0, row_ofs} + {11'd0, col_ofs};
wire [18:0]  col_addr = 19'h1F800 + {3'd0, colptr} + {7'd0, row_ofs} + {11'd0, col_ofs};

// full-colour characters: 64 bytes each at character number * 64, one byte per pixel
logic  [7:0] f_scr_hi, f_col0;
logic        f_fcm;
wire [12:0]  char_num  = {f_scr_hi[4:0], f_scr};
wire         cell_fcm  = (char_num[12:8] != 5'd0) ? fclrhi : fclrlo;
function automatic [18:0] fcm_addr(input logic [2:0] k, input logic vflip, input logic hflip);
	fcm_addr = {char_num, vflip ? ~text_rc : text_rc, hflip ? ~k : k};
endfunction
wire [7:0]  chr_code  = ecm ? {2'b00, f_scr[5:0]} : f_scr;
wire [15:0] chr_addr  = {vic_bank, cb[3:1], chr_code, text_rc};
wire [15:0] bmp_addr  = {vic_bank, cb[3], cell_idx[9:0], text_rc};
wire [15:0] gfx_addr  = bmm ? bmp_addr : chr_addr;
// character ROM shadows $1000-$1FFF of video banks 0 and 2 (text modes)
wire        gfx_rom   = !bmm && (gfx_addr[14:12] == 3'b001);
wire [16:0] crom_addr = {crom9 ? 5'h09 : 5'h0D, gfx_addr[11:0]};   // $29000 / $2D000

logic f_rom_sel;

// bitplane byte address: even planes in bank 0, odd planes in bank 1.  Planes
// are laid out like a VIC-II bitmap (8 bytes per character cell).
function automatic [18:0] bp_byte_addr(input int n);
	logic [2:0] sel;
	logic [15:0] base;
	// 400 line modes: the second field's lines come from the "odd" address
	sel  = (v400 && field) ? bp_addr[n][7:5] : bp_addr[n][3:1];
	base = h640 ? {sel[2:1], 14'd0} : {sel, 13'd0};
	bp_byte_addr = {bp_bank[1:0], n[0], base + {1'b0, cell_idx, text_rc}};
endfunction

always_ff @(posedge clk) begin
	if (reset) begin
		f_run <= 1'b0; f_go <= 1'b0; f_step <= '0; f_col <= '0; f_cnt <= '0;
		row_base <= '0;
	end
	else begin
		f_go <= 1'b0;
		if (ce_pix) begin
			if (hx == fetch_x0 && in_rows) begin
				f_run <= 1'b1; f_col <= '0; f_cnt <= '0; f_go <= 1'b1;
			end
			else if (f_run) begin
				if (f_cnt == cell_w - 5'd1) begin
					f_cnt <= '0;
					if (f_col == n_cols - 7'd1) f_run <= 1'b0;
					else begin f_col <= f_col + 7'd1; f_go <= 1'b1; end
				end
				else f_cnt <= f_cnt + 5'd1;
			end
			// row bookkeeping at the start of each raster line
			if (line_start) begin
				// vc is still the old line here; the new line is vc+1
				if (vc + 9'd1 == y_first) begin
					row_base <= '0;
					row_ofs  <= '0;
				end
				else if (in_rows) begin
					if (text_rc == 3'd7) begin
						row_base <= row_base + {5'd0, n_cols};
						row_ofs  <= row_ofs + {2'd0, linestep};
					end
				end
			end
		end

		// memory sequencer: address at step n, data latched at step n+2
		if (f_go) f_step <= 4'd0;
		else if (f_step != 4'd15) f_step <= f_step + 4'd1;

		if (bpm) begin
			if (f_step < 4'd8) vaddr_gfx <= bp_byte_addr(int'(f_step[2:0]));
			if (f_step >= 4'd2 && f_step < 4'd10) f_bp[f_step[2:0] - 3'd2] <= vram_q;
		end
		else if (chr16 && !bmm) begin
			// two screen bytes, two colour bytes, then 8 pixel bytes (full
			// colour) or one glyph byte
			case (f_step)
				4'd0: vaddr_gfx <= scr_addr;
				4'd1: vaddr_gfx <= scr_addr + 19'd1;
				4'd2: begin f_scr <= vram_q; vaddr_gfx <= col_addr; end
				4'd3: begin f_scr_hi <= vram_q; vaddr_gfx <= col_addr + 19'd1; end
				4'd4: begin
					f_col0 <= vram_q;
					f_fcm  <= cell_fcm;
					if (cell_fcm) vaddr_gfx <= fcm_addr(3'd0, vram_q[7], vram_q[6]);
					else begin
						vaddr_gfx <= gfx_rom ? {2'b00, crom_addr} : {3'b000, gfx_addr};
						f_rom_sel <= gfx_rom;
					end
				end
				4'd5: begin
					f_col_byte <= vram_q;
					if (f_fcm) vaddr_gfx <= fcm_addr(3'd1, f_col0[7], f_col0[6]);
				end
				default: begin
					if (f_fcm) begin
						if (f_step >= 4'd6 && f_step <= 4'd13) f_bp[f_step[2:0] - 3'd6] <= vram_q;
						if (f_step >= 4'd6 && f_step <= 4'd11) vaddr_gfx <= fcm_addr(f_step[2:0] - 3'd4, f_col0[7], f_col0[6]);
					end
					else if (f_step == 4'd6) f_gfx <= f_rom_sel ? vrom_q : vram_q;
				end
			endcase
		end
		else begin
			case (f_step)
				4'd0: vaddr_gfx <= scr_addr;
				4'd1: vaddr_gfx <= bmm ? 19'h1F800 + {7'd0, cell_idx} : col_addr;   // colour RAM
				4'd2: begin f_scr <= vram_q; f_fcm <= 1'b0; end
				4'd3: begin
					f_col_byte <= vram_q;
					vaddr_gfx  <= gfx_rom ? {2'b00, crom_addr} : {3'b000, gfx_addr};
					f_rom_sel  <= gfx_rom;
				end
				4'd5: f_gfx <= f_rom_sel ? vrom_q : vram_q;
				default: ;
			endcase
		end
	end
end

// ------------------------------------------------------------------ pixel pipeline
logic  [7:0] sh_gfx, sh_scr, sh_col;
logic  [7:0] sh_bp [8];
logic        sh_on;           // inside the fetched area
logic        sh_fcm;          // the cell is a full-colour character
logic  [4:0] d_cnt;
logic  [6:0] d_col;
logic        d_run;
logic        mc_phase;
logic  [1:0] mc_bits;

wire blink_on = frame[4];

// attribute processing happens when the cell is loaded
logic [7:0] ld_gfx, ld_fg;
always_comb begin
	ld_gfx = f_gfx;
	ld_fg  = {4'h0, f_col_byte[3:0]};
	if (attr && !bmm && !mcm && !ecm) begin
		if (f_col_byte[4] && blink_on) begin
			if (f_col_byte[7:5] == 3'd0) ld_gfx = 8'h00;     // plain blink
		end
		else begin
			if (f_col_byte[7] && text_rc == 3'd7) ld_gfx = 8'hFF;   // underline
			if (f_col_byte[5]) ld_gfx = ~ld_gfx;                    // reverse
			if (f_col_byte[6]) ld_fg[4] = 1'b1;                     // bold / alternate palette
		end
	end
end

logic [7:0] gfx_idx;      // colour index of the graphics layer
logic       gfx_fg;       // foreground (for sprite priority / collisions)

wire       px      = sh_gfx[7];
wire [2:0] fcm_n   = h640 ? d_cnt[2:0] : d_cnt[3:1];     // pixel within the cell
wire [7:0] fcm_px  = sh_bp[fcm_n];
wire [1:0] px2     = mc_phase ? mc_bits : sh_gfx[7:6];

always_comb begin
	gfx_idx = col_bg0;
	gfx_fg  = 1'b0;
	if (!sh_on) begin
		gfx_idx = col_bg0;
	end
	else if (sh_fcm && !bpm) begin
		// 0 = background, $FF = the cell's foreground colour, anything else = palette entry
		if (fcm_px == 8'h00)      gfx_idx = col_bg0;
		else if (fcm_px == 8'hFF) gfx_idx = sh_col;
		else                      gfx_idx = fcm_px;
		gfx_fg = (fcm_px != 8'h00);
	end
	else if (bpm) begin
		for (int i = 0; i < 8; i++)
			gfx_idx[i] = bp_en[i] & (sh_bp[i][7] ^ bp_comp[i]);
		gfx_fg = gfx_idx[2];
	end
	else begin
		case ({ecm, bmm, mcm})
			3'b000: begin gfx_idx = px ? sh_col : col_bg0; gfx_fg = px; end
			3'b001: begin
				if (sh_col[3]) begin
					case (px2)
						2'b00: gfx_idx = col_bg0;
						2'b01: gfx_idx = col_bg1;
						2'b10: gfx_idx = col_bg2;
						2'b11: gfx_idx = {5'd0, sh_col[2:0]};
					endcase
					gfx_fg = px2[1];
				end
				else begin gfx_idx = px ? {5'd0, sh_col[2:0]} : col_bg0; gfx_fg = px; end
			end
			3'b010: begin gfx_idx = px ? {4'd0, sh_scr[7:4]} : {4'd0, sh_scr[3:0]}; gfx_fg = px; end
			3'b011: begin
				case (px2)
					2'b00: gfx_idx = col_bg0;
					2'b01: gfx_idx = {4'd0, sh_scr[7:4]};
					2'b10: gfx_idx = {4'd0, sh_scr[3:0]};
					2'b11: gfx_idx = {4'd0, sh_col[3:0]};
				endcase
				gfx_fg = px2[1];
			end
			3'b100: begin
				case (sh_scr[7:6])
					2'b00: gfx_idx = col_bg0;
					2'b01: gfx_idx = col_bg1;
					2'b10: gfx_idx = col_bg2;
					2'b11: gfx_idx = col_bg3;
				endcase
				if (px) gfx_idx = sh_col;
				gfx_fg = px;
			end
			default: begin gfx_idx = 8'd0; gfx_fg = 1'b0; end
		endcase
	end
end

always_ff @(posedge clk) begin
	if (reset) begin
		d_run <= 1'b0; sh_on <= 1'b0; d_cnt <= '0; d_col <= '0; mc_phase <= 1'b0;
	end
	else if (ce_pix) begin
		logic load;
		load = 1'b0;
		if (hx == gfx_x0 && in_rows) begin
			d_run <= 1'b1; d_col <= '0; d_cnt <= '0; load = 1'b1;
		end
		else if (d_run) begin
			if (d_cnt == cell_w - 5'd1) begin
				d_cnt <= '0;
				if (d_col == n_cols - 7'd1) begin d_run <= 1'b0; sh_on <= 1'b0; end
				else begin d_col <= d_col + 7'd1; load = 1'b1; end
			end
			else d_cnt <= d_cnt + 5'd1;
		end

		if (load) begin
			sh_gfx <= ld_gfx;
			sh_scr <= f_scr;
			sh_col <= (bmm || mcm || ecm) ? f_col_byte : ld_fg;
			for (int i = 0; i < 8; i++) sh_bp[i] <= f_bp[i];
			sh_fcm <= f_fcm && chr16;
			sh_on  <= 1'b1;
			mc_phase <= 1'b0;
		end
		else if (h640 || d_cnt[0]) begin
			// one graphics pixel elapsed (every 640-pixel in 80 column mode,
			// every second one in 40 column mode)
			sh_gfx <= {sh_gfx[6:0], 1'b0};
			if (bpm) for (int i = 0; i < 8; i++) sh_bp[i] <= {sh_bp[i][6:0], 1'b0};
			mc_phase <= ~mc_phase;
			if (!mc_phase) mc_bits <= sh_gfx[7:6];
		end
	end
end

// ------------------------------------------------------------------ sprites
// The data for the next raster line is fetched during horizontal blanking,
// then shifted out against the X counter.  Besides the VIC-II formats this
// handles the VIC-IV 16-colour sprites (16 pixels of 4 bits, 8 bytes per row),
// 64 pixel wide sprites and the programmable sprite height.
logic  [7:0] spr_active;
logic  [7:0] spr_row [8];
logic  [7:0] spr_yflop;
logic [63:0] spr_data [8];     // one row, left-most pixel in the top bits
logic [63:0] spr_sh [8];
logic  [7:0] spr_shifting;
logic  [7:0] spr_xflop, spr_mcflop;
logic  [5:0] spr_left [8];     // pixels still to come after the current one
logic  [1:0] spr_pix [8];
logic  [3:0] spr_pix16 [8];
logic  [7:0] spr_ptr;

wire [7:0] spr_wide = (spr16 | sprx64) & {8{vic4_mode}};     // 8 bytes per row
wire [7:0] spr_c16  = spr16 & {8{vic4_mode}};

// fetch FSM: runs in horizontal blanking, up to 13 steps per sprite
logic  [2:0] sf_n;
logic  [3:0] sf_step;
logic        sf_run;
logic [18:0] spr_vaddr;
logic        spr_bus;       // sprite fetch owns vaddr

wire [15:0] spr_ptr_addr  = (h640 ? {vic_bank, vm[3:1], 11'h7F8} : {vic_bank, vm, 10'h3F8}) + {13'd0, sf_n};
wire [18:0] spr_ptr_addr4 = sprptr_adr[18:0] + {15'd0, sf_n, 1'b0};
wire  [7:0] sf_row        = spr_row[sf_n];
wire [18:0] spr_row_ofs   = spr_wide[sf_n] ? {8'd0, sf_row, 3'd0} : {9'd0, {sf_row, 1'b0} + {1'b0, sf_row}};
wire  [3:0] sf_last       = spr_wide[sf_n] ? 4'd12 : 4'd7;

always_ff @(posedge clk) begin
	if (reset) begin
		spr_active <= '0; sf_run <= 1'b0; spr_bus <= 1'b0; spr_yflop <= '0;
		sf_n <= '0; sf_step <= '0;
	end
	else begin
		if (ce_pix && line_start) begin
			// evaluate sprites for the new line (vc+1)
			for (int i = 0; i < 8; i++) begin
				if (spr_active[i]) begin
					if (!spr_yexp[i] || spr_yflop[i]) begin
						if (spr_row[i] == ((sprhgten[i] && vic4_mode) ? sprhght - 8'd1 : 8'd20)) spr_active[i] <= 1'b0;
						else spr_row[i] <= spr_row[i] + 8'd1;
					end
					spr_yflop[i] <= ~spr_yflop[i];
				end
				else if (spr_en[i] && spr_y[i] == vc[7:0]) begin
					// VIC-II shows a sprite from the line after the Y match
					spr_active[i] <= 1'b1;
					spr_row[i]    <= '0;
					spr_yflop[i]  <= 1'b0;
				end
			end
			sf_run <= 1'b1; sf_n <= '0; sf_step <= '0; spr_bus <= 1'b1;
		end
		else if (sf_run) begin
			sf_step <= sf_step + 4'd1;
			// address at step n, data two steps later
			case (sf_step)
				4'd0: spr_vaddr <= sprptr16 ? spr_ptr_addr4 : {3'b000, spr_ptr_addr};
				4'd1: spr_vaddr <= spr_vaddr + 19'd1;                   // high pointer byte (16-bit pointers)
				4'd2: spr_ptr <= vram_q;
				4'd3: spr_vaddr <= (sprptr16 ? {vram_q[4:0], spr_ptr, 6'd0} : {3'b000, vic_bank, spr_ptr, 6'd0}) + spr_row_ofs;
				default: spr_vaddr <= spr_vaddr + 19'd1;
			endcase
			if (sf_step >= 4'd5 && sf_step <= 4'd12)
				spr_data[sf_n][(4'd12 - sf_step) * 8 +: 8] <= vram_q;      // byte 0 lands in [63:56]
			if (sf_step == 4'd5 && !spr_wide[sf_n]) spr_data[sf_n][39:0] <= '0;
			if (sf_step == sf_last) begin
				sf_step <= '0;
				if (sf_n == 3'd7) begin sf_run <= 1'b0; spr_bus <= 1'b0; end
				else sf_n <= sf_n + 3'd1;
			end
		end
	end
end

// sprite shifters (320-mode pixels)
wire lores_tick = ce_pix && hx[0];
always_ff @(posedge clk) begin
	if (reset) begin
		spr_shifting <= '0;
	end
	else if (lores_tick) begin
		for (int i = 0; i < 8; i++) begin
			if (x == 10'(X_BLANK0)) begin
				spr_shifting[i] <= 1'b0;
				spr_pix[i] <= 2'b00;
			end
			else if (spr_active[i] && !spr_shifting[i] && x[8:0] == spr_x[i] && x < 10'd512) begin
				spr_shifting[i] <= 1'b1;
				spr_sh[i]     <= spr_data[i];
				spr_xflop[i]  <= 1'b0;
				spr_mcflop[i] <= 1'b0;
				spr_left[i]   <= spr_c16[i] ? 6'd15 : (sprx64[i] && vic4_mode) ? 6'd63 : 6'd23;
				spr_pix[i]    <= spr_mc[i] ? spr_data[i][63:62] : {spr_data[i][63], 1'b0};
				spr_pix16[i]  <= spr_data[i][63:60];
			end
			else if (spr_shifting[i]) begin
				if (!spr_xexp[i] || spr_xflop[i]) begin
					if (spr_left[i] == 6'd0) spr_shifting[i] <= 1'b0;
					spr_left[i] <= spr_left[i] - 6'd1;
					if (spr_c16[i]) begin
						spr_sh[i]    <= {spr_sh[i][59:0], 4'd0};
						spr_pix16[i] <= spr_sh[i][59:56];
					end
					else begin
						spr_sh[i] <= {spr_sh[i][62:0], 1'b0};
						spr_mcflop[i] <= ~spr_mcflop[i];
						if (spr_mc[i]) begin
							if (spr_mcflop[i]) spr_pix[i] <= spr_sh[i][62:61];
						end
						else spr_pix[i] <= {spr_sh[i][62], 1'b0};
					end
				end
				spr_xflop[i] <= ~spr_xflop[i];
			end
		end
	end
end

logic       spr_any, spr_front;
logic [7:0] spr_idx;
logic [7:0] spr_hit;
always_comb begin
	spr_any = 1'b0; spr_front = 1'b0; spr_idx = 8'd0;
	// a 16-colour pixel is transparent when it equals the sprite's colour register
	for (int i = 0; i < 8; i++)
		spr_hit[i] = spr_shifting[i] && (spr_c16[i] ? (spr_pix16[i] != spr_col[i][3:0]) : (spr_pix[i] != 2'b00));
	for (int i = 7; i >= 0; i--) begin
		if (spr_hit[i]) begin
			spr_any   = 1'b1;
			spr_front = ~spr_pri[i];
			// each 16-colour sprite has its own block of 16 palette entries
			if (spr_c16[i]) spr_idx = {1'b0, 3'(i), spr_pix16[i]};
			else begin
				case (spr_pix[i])
					2'b01:   spr_idx = spr_mc0;
					2'b11:   spr_idx = spr_mc1;
					default: spr_idx = spr_col[i];
				endcase
			end
		end
	end
end

wire multi_hit = (spr_hit & (spr_hit - 8'd1)) != 8'd0;
wire in_window = !bord_q;
always_ff @(posedge clk) begin
	ss_set_any <= 1'b0; sd_set_any <= 1'b0;
	if (lores_tick) begin
		if (multi_hit) begin ss_set_any <= 1'b1; ss_set <= spr_hit; end
		if (spr_any && gfx_fg && sh_on && in_window) begin sd_set_any <= 1'b1; sd_set <= spr_hit; end
	end
end

// ------------------------------------------------------------------ output mux
// vaddr is shared between the character/bitplane fetch and the sprite fetch;
// the sprite fetch only runs in horizontal blanking.
assign vaddr = spr_bus ? spr_vaddr : vaddr_gfx;

// the graphics shifter shows a pixel one ce_pix after its X position, so the
// border window is delayed to match
logic bord_q;
always_ff @(posedge clk) if (ce_pix) bord_q <= vborder || hborder;

logic [7:0] idx_c;
always_comb begin
	if (bord_q) idx_c = col_border;
	else if (spr_any && (spr_front || !gfx_fg)) idx_c = spr_idx;
	else idx_c = gfx_idx;
end

logic hbl_q, vbl_q, hs_q, vs_q;

always_ff @(posedge clk) begin
	if (ce_pix) begin
		pix_idx <= idx_c;
		hbl_q <= hbl_i; vbl_q <= vbl_i; hs_q <= hs_i; vs_q <= vs_i;
		// the palette RAM outputs (pr_q..) now hold the entry for pix_idx
		if (pix_idx[7:4] == 4'd0 && !palram) {r, g, b} <= rom_pal(pix_idx[3:0]);
		else begin r <= pr_q[3:0]; g <= pg_q; b <= pb_q; end
		hblank <= hbl_q; vblank <= vbl_q; hsync <= hs_q; vsync <= vs_q;
	end
end

endmodule
