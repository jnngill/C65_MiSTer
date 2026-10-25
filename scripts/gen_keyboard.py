#!/usr/bin/env python3
"""Generate rtl/c65_keyboard.sv: PS/2 (hps_io ps2_key) to C65 keyboard matrix.

Host layouts US / UK / DE are mapped symbolically: the character printed on
the host key cap is produced on the C65, pressing or releasing the C65 SHIFT
key behind the scenes where the two keyboards disagree.  Layout 3 is the
positional map used by the MiSTer C64 core.
"""
import os

# ---------------------------------------------------------------- C65 matrix
# index = column * 8 + row; columns 0-7 = CIA1 PA bits, column 8 = C65 extra
MATRIX = [
    ["DEL", "RETURN", "RIGHT", "F7", "F1", "F3", "F5", "DOWN"],
    ["3", "W", "A", "4", "Z", "S", "E", "LSHIFT"],
    ["5", "R", "D", "6", "C", "F", "T", "X"],
    ["7", "Y", "G", "8", "B", "H", "U", "V"],
    ["9", "I", "J", "0", "M", "K", "O", "N"],
    ["PLUS", "P", "L", "MINUS", "DOT", "COLON", "AT", "COMMA"],
    ["POUND", "STAR", "SEMI", "HOME", "RSHIFT", "EQUAL", "UPARROW", "SLASH"],
    ["1", "LEFTARROW", "CTRL", "2", "SPACE", "CBM", "Q", "STOP"],
    ["NOSCROLL", "TAB", "ALT", "HELP", "F9", "F11", "F13", "ESC"],
]
KEY = {n: c * 8 + r for c, col in enumerate(MATRIX) for r, n in enumerate(col)}

ASIS, OFF, ON = 0, 1, 2      # what to do with the C65 SHIFT key while held

# symbol name -> (C65 key, shift handling)
SYM = {
    "EXCL": ("1", ON), "DQUOTE": ("2", ON), "HASH": ("3", ON), "DOLLAR": ("4", ON), "PERCENT": ("5", ON),
    "AMP": ("6", ON), "QUOTE": ("7", ON), "LPAREN": ("8", ON), "RPAREN": ("9", ON),
    "PLUS": ("PLUS", OFF), "MINUS": ("MINUS", OFF), "AT": ("AT", OFF), "STAR": ("STAR", OFF),
    "EQUAL": ("EQUAL", OFF), "COLON": ("COLON", OFF), "SEMI": ("SEMI", OFF), "COMMA": ("COMMA", OFF),
    "DOT": ("DOT", OFF), "SLASH": ("SLASH", OFF), "LESS": ("COMMA", ON), "GREATER": ("DOT", ON),
    "QUESTION": ("SLASH", ON), "LBRACKET": ("COLON", ON), "RBRACKET": ("SEMI", ON),
    "CARET": ("UPARROW", OFF), "PI": ("UPARROW", ON), "POUND": ("POUND", OFF),
    "LEFTARROW": ("LEFTARROW", OFF), "UNDERSCORE": ("LEFTARROW", OFF), "BACKSLASH": ("POUND", OFF),
    "BAR": ("POUND", ON),
}
for d in "0123456789":
    SYM["D" + d] = (d, OFF)

# ---------------------------------------------------------------- host keys
LETTERS = {0x1C: "A", 0x32: "B", 0x21: "C", 0x23: "D", 0x24: "E", 0x2B: "F", 0x34: "G", 0x33: "H", 0x43: "I",
           0x3B: "J", 0x42: "K", 0x4B: "L", 0x3A: "M", 0x31: "N", 0x44: "O", 0x4D: "P", 0x15: "Q", 0x2D: "R",
           0x1B: "S", 0x2C: "T", 0x3C: "U", 0x2A: "V", 0x1D: "W", 0x22: "X", 0x35: "Y", 0x1A: "Z"}

# keys that are the same on every layout: code -> (C65 key, shift handling)
COMMON = {
    0x29: ("SPACE", ASIS), 0x5A: ("RETURN", ASIS), 0x15A: ("RETURN", ASIS), 0x66: ("DEL", ASIS),
    0x171: ("DEL", ASIS), 0x12: ("LSHIFT", ASIS), 0x59: ("RSHIFT", ASIS), 0x14: ("CTRL", ASIS),
    0x114: ("CTRL", ASIS), 0x11F: ("CBM", ASIS), 0x127: ("CBM", ASIS), 0x11: ("ALT", ASIS), 0x111: ("ALT", ASIS),
    0x0D: ("TAB", ASIS), 0x76: ("STOP", ASIS), 0x169: ("ESC", ASIS), 0x16C: ("HOME", ASIS),
    0x170: ("POUND", ASIS), 0x17D: ("HELP", ASIS), 0x17A: ("UPARROW", ASIS), 0x7E: ("NOSCROLL", ASIS),
    0x174: ("RIGHT", ASIS), 0x172: ("DOWN", ASIS), 0x16B: ("RIGHT", ON), 0x175: ("DOWN", ON),
    0x05: ("F1", ASIS), 0x04: ("F3", ASIS), 0x03: ("F5", ASIS), 0x83: ("F7", ASIS),
    0x06: ("F1", ON), 0x0C: ("F3", ON), 0x0B: ("F5", ON), 0x0A: ("F7", ON),
    0x01: ("F9", ASIS), 0x09: ("F11", ASIS), 0x07: ("F13", ASIS),
    # numeric keypad
    0x70: ("0", OFF), 0x69: ("1", OFF), 0x72: ("2", OFF), 0x7A: ("3", OFF), 0x6B: ("4", OFF), 0x73: ("5", OFF),
    0x74: ("6", OFF), 0x6C: ("7", OFF), 0x75: ("8", OFF), 0x7D: ("9", OFF), 0x71: ("DOT", OFF),
    0x79: ("PLUS", OFF), 0x7B: ("MINUS", OFF), 0x7C: ("STAR", OFF), 0x14A: ("SLASH", OFF),
}

# symbol keys per layout: code -> (unshifted symbol, shifted symbol); None = dead
US = {
    0x0E: ("LEFTARROW", "PI"), 0x16: ("D1", "EXCL"), 0x1E: ("D2", "AT"), 0x26: ("D3", "HASH"),
    0x25: ("D4", "DOLLAR"), 0x2E: ("D5", "PERCENT"), 0x36: ("D6", "CARET"), 0x3D: ("D7", "AMP"),
    0x3E: ("D8", "STAR"), 0x46: ("D9", "LPAREN"), 0x45: ("D0", "RPAREN"), 0x4E: ("MINUS", "UNDERSCORE"),
    0x55: ("EQUAL", "PLUS"), 0x54: ("LBRACKET", "LBRACKET"), 0x5B: ("RBRACKET", "RBRACKET"),
    0x5D: ("BACKSLASH", "BAR"), 0x4C: ("SEMI", "COLON"), 0x52: ("QUOTE", "DQUOTE"),
    0x41: ("COMMA", "LESS"), 0x49: ("DOT", "GREATER"), 0x4A: ("SLASH", "QUESTION"),
}
UK = dict(US)
UK.update({
    0x1E: ("D2", "DQUOTE"), 0x26: ("D3", "POUND"), 0x52: ("QUOTE", "AT"),
    0x5D: ("HASH", "PI"), 0x61: ("BACKSLASH", "BAR"),
})
DE = {
    0x0E: ("CARET", "PI"), 0x16: ("D1", "EXCL"), 0x1E: ("D2", "DQUOTE"), 0x26: ("D3", "AT"),
    0x25: ("D4", "DOLLAR"), 0x2E: ("D5", "PERCENT"), 0x36: ("D6", "AMP"), 0x3D: ("D7", "SLASH"),
    0x3E: ("D8", "LPAREN"), 0x46: ("D9", "RPAREN"), 0x45: ("D0", "EQUAL"), 0x4E: ("POUND", "QUESTION"),
    0x55: ("QUOTE", "LEFTARROW"), 0x54: ("AT", "AT"), 0x5B: ("PLUS", "STAR"), 0x5D: ("HASH", "QUOTE"),
    0x4C: ("LBRACKET", "LBRACKET"), 0x52: ("RBRACKET", "RBRACKET"), 0x61: ("LESS", "GREATER"),
    0x41: ("COMMA", "SEMI"), 0x49: ("DOT", "COLON"), 0x4A: ("MINUS", "UNDERSCORE"),
}
# positional map (as the MiSTer C64 core): the key in the same place as on a C64
POS = {0x0E: "LEFTARROW", 0x16: "1", 0x1E: "2", 0x26: "3", 0x25: "4", 0x2E: "5", 0x36: "6", 0x3D: "7",
       0x3E: "8", 0x46: "9", 0x45: "0", 0x4E: "PLUS", 0x55: "MINUS", 0x54: "AT", 0x5B: "STAR",
       0x5D: "EQUAL", 0x4C: "COLON", 0x52: "SEMI", 0x41: "COMMA", 0x49: "DOT", 0x4A: "SLASH"}


def build(layout):
    """return {(shift, code): (key index, mode)}"""
    t = {}
    for sh in (0, 1):
        for code, (k, m) in COMMON.items():
            t[(sh, code)] = (KEY[k], m)
        for code, name in LETTERS.items():
            if layout == "DE" and name in "YZ":
                name = "Z" if name == "Y" else "Y"
            t[(sh, code)] = (KEY[name], ASIS)
    if layout == "POS":
        for sh in (0, 1):
            for code, k in POS.items():
                t[(sh, code)] = (KEY[k], ASIS)
        return t
    for code, syms in {"US": US, "UK": UK, "DE": DE}[layout].items():
        for sh in (0, 1):
            k, m = SYM[syms[sh]]
            # only force the C65 shift state where it differs from the host's
            if (m == ON and sh == 1) or (m == OFF and sh == 0):
                m = ASIS
            t[(sh, code)] = (KEY[k], m)
    return t


HEADER = '''// PS/2 (MiSTer hps_io ps2_key) to C65 keyboard matrix.
// GENERATED by scripts/gen_keyboard.py -- edit the tables there.
//
// Columns 0-7 are scanned by CIA1 port A, column 8 (C65 extra keys) by
// UART port bit 1 ($D607); rows are read back on CIA1 port B.
//
// layout: 0 = US, 1 = UK, 2 = DE (symbolic: the host key cap legend is what
// the C65 sees), 3 = positional (key positions as on a C64/C65).
//
// Keys common to all layouts:
//   F1 F3 F5 F7 = same, F2 F4 F6 F8 = shifted, F9 = F9, F10 = F11, F12 = F13
//   F11 = RESTORE, Esc = RUN/STOP, End = ESC, Tab = TAB, Alt = ALT, Win = C=
//   Insert = pound, PgUp = HELP, PgDn = up arrow, Home = HOME (Shift = CLR)
//   Scroll Lock = NO SCROLL, Caps Lock = CAPS LOCK, cursor keys = cursor keys

module c65_keyboard (
	input  logic        clk,
	input  logic        reset,
	input  logic  [1:0] layout,
	input  logic [10:0] ps2_key,     // [10] toggles on event, [9] pressed, [8] extended, [7:0] code
	input  logic  [7:0] col_sel,     // CIA1 PA (0 = column selected)
	input  logic        col8_sel,    // 0 = extra column selected
	input  logic  [7:0] row_drive,   // CIA1 PB as driven by the CIA (0 = row pulled low)
	output logic  [7:0] row_in,      // to CIA1 PB
	output logic  [7:0] col_in,      // to CIA1 PA (keys read "backwards")
	output logic        restore_n,
	output logic        capslock_n,
	output logic [71:0] matrix,      // MEGA65 $D613/$D614: the keys as the matrix sees them, 1 = pressed
	output logic        crsr_left,   // MEGA65 $D60F.0 / .1: cursor left / up held (they reach the
	output logic        crsr_up,     // matrix as SHIFT + cursor right / down)
	output logic        key_event,   // MEGA65 $D610 queue: a key went down (one clk) ...
	output logic  [6:0] key_index,   // ... which matrix key (col * 8 + row)
	output logic        key_shift,   // ... and the C65 SHIFT / CTRL / MEGA state with it
	output logic        key_ctrl,
	output logic        key_mega
);

localparam logic [6:0] K_NONE   = 7'd127;
localparam logic [6:0] K_LSHIFT = 7'd%d;
localparam logic [6:0] K_RSHIFT = 7'd%d;

// {shift handling, key}: handling 0 = leave SHIFT alone, 1 = release it, 2 = press it
function automatic [8:0] keymap(input logic [1:0] lay, input logic shift, input logic [8:0] code);
	keymap = {2'd0, K_NONE};
	case ({lay, shift, code})
'''

FOOTER = '''		default: ;
	endcase
endfunction

logic [71:0] keys;        // 1 = pressed, index = col*8+row
logic [71:0] f_on, f_off; // held keys that force the C65 SHIFT state
logic        ps2_stb;
logic        caps;

// A key that changes the C65 SHIFT state (":" is shift+";" on a PC but its
// own key on the C65) must not meet a keyboard scan that is half done: the
// ROM could read SHIFT before the change and the key after it, and type
// shift+":" = "[".  So the new key is kept out of the matrix for ~2 ms after
// the SHIFT change (longer than one scan), and on release the SHIFT override
// is kept for ~2 ms after the key has gone.
logic [71:0] hold;        // pressed, not yet visible
logic        lin_off, lin_on;
logic [16:0] hold_cnt, lin_cnt;

assign capslock_n = ~caps;

wire       host_shift = keys[K_LSHIFT] | keys[K_RSHIFT];
wire [8:0] m_now = keymap(layout, host_shift, ps2_key[8:0]);
wire [8:0] m_s0  = keymap(layout, 1'b0, ps2_key[8:0]);
wire [8:0] m_s1  = keymap(layout, 1'b1, ps2_key[8:0]);

always_ff @(posedge clk) begin
	ps2_stb <= ps2_key[10];
	key_event <= 1'b0;
	if (reset) begin
		keys <= '0; f_on <= '0; f_off <= '0; restore_n <= 1'b1; caps <= 1'b0; crsr_left <= 1'b0; crsr_up <= 1'b0;
		hold <= '0; lin_off <= 1'b0; lin_on <= 1'b0; hold_cnt <= '0; lin_cnt <= '0;
	end
	else begin
		if (hold_cnt != 0) hold_cnt <= hold_cnt - 1'd1; else hold <= '0;
		if (lin_cnt != 0)  lin_cnt  <= lin_cnt - 1'd1;  else begin lin_off <= 1'b0; lin_on <= 1'b0; end
		if (ps2_stb != ps2_key[10]) begin
		if (ps2_key[9]) begin
			if (m_now[6:0] != K_NONE) begin
				keys[m_now[6:0]]  <= 1'b1;
				key_event <= 1'b1;
				key_index <= m_now[6:0];
				key_shift <= (m_now[8:7] == 2'd2) || (m_now[8:7] == 2'd0 && host_shift);
				key_ctrl  <= keys[58];
				key_mega  <= keys[61];
				f_off[m_now[6:0]] <= (m_now[8:7] == 2'd1);
				f_on[m_now[6:0]]  <= (m_now[8:7] == 2'd2);
				if (m_now[8:7] != 2'd0) begin hold[m_now[6:0]] <= 1'b1; hold_cnt <= 17'd65535; end
			end
		end
		else begin
			// the shift state may have changed since the press: release both candidates
			if (m_s0[6:0] != K_NONE) begin keys[m_s0[6:0]] <= 1'b0; f_off[m_s0[6:0]] <= 1'b0; f_on[m_s0[6:0]] <= 1'b0; hold[m_s0[6:0]] <= 1'b0; end
			if (m_s1[6:0] != K_NONE) begin keys[m_s1[6:0]] <= 1'b0; f_off[m_s1[6:0]] <= 1'b0; f_on[m_s1[6:0]] <= 1'b0; hold[m_s1[6:0]] <= 1'b0; end
			if ((m_s0[6:0] != K_NONE && (f_off[m_s0[6:0]] || f_on[m_s0[6:0]])) || (m_s1[6:0] != K_NONE && (f_off[m_s1[6:0]] || f_on[m_s1[6:0]]))) begin
				lin_off  <= (m_s0[6:0] != K_NONE && f_off[m_s0[6:0]]) || (m_s1[6:0] != K_NONE && f_off[m_s1[6:0]]);
				lin_on   <= (m_s0[6:0] != K_NONE && f_on[m_s0[6:0]])  || (m_s1[6:0] != K_NONE && f_on[m_s1[6:0]]);
				lin_cnt  <= 17'd65535;
			end
		end
		if (ps2_key[8:0] == 9'h078) restore_n <= ~ps2_key[9];        // F11
		if (ps2_key[8:0] == 9'h058 && ps2_key[9]) caps <= ~caps;     // Caps Lock
		if (ps2_key[8:0] == 9'h16B) crsr_left <= ps2_key[9];
		if (ps2_key[8:0] == 9'h175) crsr_up   <= ps2_key[9];
		end
	end
end

// matrix scan, including "reverse" scanning (rows driven, columns read)
always_comb begin
	logic [71:0] k;
	k = keys & ~hold;
	if (|f_off || lin_off) begin k[K_LSHIFT] = 1'b0; k[K_RSHIFT] = 1'b0; end
	else if (|f_on || lin_on) k[K_RSHIFT] = 1'b1;
	matrix = k;
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
'''


def main():
    names = {v: k for k, v in KEY.items()}
    out = [HEADER % (KEY["LSHIFT"], KEY["RSHIFT"])]
    for li, lay in enumerate(("US", "UK", "DE", "POS")):
        out.append("\t\t// ---- layout %d: %s\n" % (li, lay))
        t = build(lay)
        for (sh, code) in sorted(t, key=lambda x: (x[1], x[0])):
            idx, mode = t[(sh, code)]
            out.append("\t\t{2'd%d, 1'b%d, 9'h%03X}: keymap = {2'd%d, 7'd%d};   // %s%s\n" % (
                li, sh, code, mode, idx, names[idx], ("", " (shift off)", " (shift on)")[mode]))
    out.append(FOOTER)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl", "c65_keyboard.sv")
    open(path, "w", newline="\n").write("".join(out))


if __name__ == "__main__":
    main()
