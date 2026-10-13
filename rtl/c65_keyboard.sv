// PS/2 (MiSTer hps_io ps2_key) to C65 keyboard matrix.
//
// Columns 0-7 are scanned by CIA1 port A, column 8 (C65 extra keys) by
// UART port bit 1 ($D607); rows are read back on CIA1 port B.
//
// Host key map (positional, like the MiSTer C64 core):
//   F1 F3 F5 F7 = same, F2 F4 F6 F8 = shifted, F9 = F9, F10 = F11, F12 = F13
//   F11 = RESTORE, Esc = RUN/STOP, End = ESC, ` = left arrow, Tab = TAB
//   Alt = ALT, Win = C=, Insert = pound, PgUp = HELP, PgDn = up arrow
//   Home = HOME, Scroll Lock = NO SCROLL, Caps Lock = CAPS LOCK
//   cursor left / up = shifted cursor right / down

module c65_keyboard (
	input  logic        clk,
	input  logic        reset,
	input  logic [10:0] ps2_key,     // [10] toggles on event, [9] pressed, [8] extended, [7:0] code
	input  logic  [7:0] col_sel,     // CIA1 PA (0 = column selected)
	input  logic        col8_sel,    // 0 = extra column selected
	input  logic  [7:0] row_drive,   // CIA1 PB as driven by the CIA (0 = row pulled low)
	output logic  [7:0] row_in,      // to CIA1 PB
	output logic  [7:0] col_in,      // to CIA1 PA (keys read "backwards")
	output logic        restore_n,
	output logic        capslock_n
);

logic [71:0] keys;        // 1 = pressed, index = col*8+row
logic        shift_virt;  // a host key that implies SHIFT is down
logic  [5:0] virt;        // which implied-shift keys are down
logic        ps2_stb;
logic        caps;

assign capslock_n = ~caps;

always_ff @(posedge clk) begin
	ps2_stb <= ps2_key[10];
	if (reset) begin
		keys <= '0; virt <= '0; restore_n <= 1'b1; caps <= 1'b0;
	end
	else if (ps2_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h001: keys[68] <= ps2_key[9];   // F9
			9'h003: keys[6] <= ps2_key[9];   // F5
			9'h004: keys[5] <= ps2_key[9];   // F3
			9'h005: keys[4] <= ps2_key[9];   // F1
			9'h007: keys[70] <= ps2_key[9];   // F13 (host F12)
			9'h009: keys[69] <= ps2_key[9];   // F11
			9'h00D: keys[65] <= ps2_key[9];   // TAB
			9'h00E: keys[57] <= ps2_key[9];   // LEFTARROW
			9'h011: keys[66] <= ps2_key[9];   // ALT
			9'h012: keys[15] <= ps2_key[9];   // LSHIFT
			9'h014: keys[58] <= ps2_key[9];   // CTRL
			9'h015: keys[62] <= ps2_key[9];   // Q
			9'h016: keys[56] <= ps2_key[9];   // 1
			9'h01A: keys[12] <= ps2_key[9];   // Z
			9'h01B: keys[13] <= ps2_key[9];   // S
			9'h01C: keys[10] <= ps2_key[9];   // A
			9'h01D: keys[9] <= ps2_key[9];   // W
			9'h01E: keys[59] <= ps2_key[9];   // 2
			9'h021: keys[20] <= ps2_key[9];   // C
			9'h022: keys[23] <= ps2_key[9];   // X
			9'h023: keys[18] <= ps2_key[9];   // D
			9'h024: keys[14] <= ps2_key[9];   // E
			9'h025: keys[11] <= ps2_key[9];   // 4
			9'h026: keys[8] <= ps2_key[9];   // 3
			9'h029: keys[60] <= ps2_key[9];   // SPACE
			9'h02A: keys[31] <= ps2_key[9];   // V
			9'h02B: keys[21] <= ps2_key[9];   // F
			9'h02C: keys[22] <= ps2_key[9];   // T
			9'h02D: keys[17] <= ps2_key[9];   // R
			9'h02E: keys[16] <= ps2_key[9];   // 5
			9'h031: keys[39] <= ps2_key[9];   // N
			9'h032: keys[28] <= ps2_key[9];   // B
			9'h033: keys[29] <= ps2_key[9];   // H
			9'h034: keys[26] <= ps2_key[9];   // G
			9'h035: keys[25] <= ps2_key[9];   // Y
			9'h036: keys[19] <= ps2_key[9];   // 6
			9'h03A: keys[36] <= ps2_key[9];   // M
			9'h03B: keys[34] <= ps2_key[9];   // J
			9'h03C: keys[30] <= ps2_key[9];   // U
			9'h03D: keys[24] <= ps2_key[9];   // 7
			9'h03E: keys[27] <= ps2_key[9];   // 8
			9'h041: keys[47] <= ps2_key[9];   // COMMA
			9'h042: keys[37] <= ps2_key[9];   // K
			9'h043: keys[33] <= ps2_key[9];   // I
			9'h044: keys[38] <= ps2_key[9];   // O
			9'h045: keys[35] <= ps2_key[9];   // 0
			9'h046: keys[32] <= ps2_key[9];   // 9
			9'h049: keys[44] <= ps2_key[9];   // DOT
			9'h04A: keys[55] <= ps2_key[9];   // SLASH
			9'h04B: keys[42] <= ps2_key[9];   // L
			9'h04C: keys[45] <= ps2_key[9];   // COLON
			9'h04D: keys[41] <= ps2_key[9];   // P
			9'h04E: keys[40] <= ps2_key[9];   // PLUS
			9'h052: keys[50] <= ps2_key[9];   // SEMI
			9'h054: keys[46] <= ps2_key[9];   // AT
			9'h055: keys[43] <= ps2_key[9];   // MINUS
			9'h059: keys[52] <= ps2_key[9];   // RSHIFT
			9'h05A: keys[1] <= ps2_key[9];   // RETURN
			9'h05B: keys[49] <= ps2_key[9];   // STAR
			9'h05D: keys[53] <= ps2_key[9];   // EQUAL
			9'h066: keys[0] <= ps2_key[9];   // DEL
			9'h069: keys[56] <= ps2_key[9];   // 1
			9'h06B: keys[11] <= ps2_key[9];   // 4
			9'h06C: keys[24] <= ps2_key[9];   // 7
			9'h070: keys[35] <= ps2_key[9];   // 0
			9'h071: keys[44] <= ps2_key[9];   // DOT
			9'h072: keys[59] <= ps2_key[9];   // 2
			9'h073: keys[16] <= ps2_key[9];   // 5
			9'h074: keys[19] <= ps2_key[9];   // 6
			9'h075: keys[27] <= ps2_key[9];   // 8
			9'h076: keys[63] <= ps2_key[9];   // STOP
			9'h079: keys[40] <= ps2_key[9];   // PLUS
			9'h07A: keys[8] <= ps2_key[9];   // 3
			9'h07B: keys[43] <= ps2_key[9];   // MINUS
			9'h07C: keys[49] <= ps2_key[9];   // STAR
			9'h07D: keys[32] <= ps2_key[9];   // 9
			9'h07E: keys[64] <= ps2_key[9];   // NOSCROLL
			9'h083: keys[3] <= ps2_key[9];   // F7
			9'h111: keys[66] <= ps2_key[9];   // ALT
			9'h114: keys[58] <= ps2_key[9];   // CTRL
			9'h11F: keys[61] <= ps2_key[9];   // CBM
			9'h127: keys[61] <= ps2_key[9];   // CBM
			9'h14A: keys[55] <= ps2_key[9];   // SLASH
			9'h15A: keys[1] <= ps2_key[9];   // RETURN
			9'h169: keys[71] <= ps2_key[9];   // ESC
			9'h16C: keys[51] <= ps2_key[9];   // HOME
			9'h170: keys[48] <= ps2_key[9];   // POUND
			9'h171: keys[0] <= ps2_key[9];   // DEL
			9'h172: keys[7] <= ps2_key[9];   // DOWN
			9'h174: keys[2] <= ps2_key[9];   // RIGHT
			9'h17D: keys[67] <= ps2_key[9];   // HELP (host PgUp)
			9'h17A: keys[54] <= ps2_key[9];   // UPARROW (host PgDn)
			9'h17E: keys[64] <= ps2_key[9];   // NOSCROLL
			9'h006: begin keys[4] <= ps2_key[9]; virt[0] <= ps2_key[9]; end   // shift + F1
			9'h00A: begin keys[3] <= ps2_key[9]; virt[1] <= ps2_key[9]; end   // shift + F7
			9'h00B: begin keys[6] <= ps2_key[9]; virt[2] <= ps2_key[9]; end   // shift + F5
			9'h00C: begin keys[5] <= ps2_key[9]; virt[3] <= ps2_key[9]; end   // shift + F3
			9'h16B: begin keys[2] <= ps2_key[9]; virt[4] <= ps2_key[9]; end   // shift + RIGHT
			9'h175: begin keys[7] <= ps2_key[9]; virt[5] <= ps2_key[9]; end   // shift + DOWN
			9'h078: restore_n <= ~ps2_key[9];   // F11
			9'h058: if (ps2_key[9]) caps <= ~caps;
			default: ;
		endcase
	end
end

assign shift_virt = |virt;

// matrix scan, including "reverse" scanning (rows driven, columns read)
always_comb begin
	logic [71:0] k;
	k = keys;
	if (shift_virt) k[52] = 1'b1;   // right shift
	row_in = 8'hFF;
	col_in = 8'hFF;
	for (int c = 0; c < 9; c++) begin
		for (int r = 0; r < 8; r++) begin
			if (k[c*8+r]) begin
				if (c == 8 ? !col8_sel : !col_sel[c]) row_in[r] = 1'b0;
				if (c < 8 && !row_drive[r]) col_in[c] = 1'b0;
			end
		end
	end
end

endmodule
