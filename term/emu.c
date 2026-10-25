/* Terminal emulations: ANSI-BBS (CP437, 80x25), VT100 (80x25, DEC line
** drawing) and PETSCII (40x25, C64 colours and fonts).
*/
#include "ascii.h"
#include "term.h"

unsigned char emu;

static const unsigned char pal_ansi[48] = {
	0, 0, 0,   10, 0, 0,   0, 10, 0,   10, 5, 0,   0, 0, 10,  10, 0, 10,  0, 10, 10,  10, 10, 10,
	5, 5, 5,   15, 5, 5,   5, 15, 5,   15, 15, 5,  5, 5, 15,  15, 5, 15,  5, 15, 15,  15, 15, 15
};
static const unsigned char pal_c64[48] = {
	0, 0, 0,   15, 15, 15,  8, 3, 3,   7, 12, 12,  8, 3, 9,   5, 10, 4,   3, 2, 9,   12, 13, 7,
	9, 5, 2,   5, 3, 0,    12, 6, 6,   4, 4, 4,   7, 7, 7,    9, 14, 8,   7, 6, 13,  10, 10, 10
};

/* ANSI state */
static unsigned char state, nparam, priv, fgc, bgc, bold, blink, inverse, g0_dec;
static unsigned char param[8];
static unsigned char save_x, save_y;
static unsigned char cursor_visible = 1;

static void colours(void)
{
	fg = fgc | (bold ? 8 : 0);
	bg = bgc | (blink ? 8 : 0);
	rev = inverse;
}

void emu_start(unsigned char mode)
{
	emu = mode;
	state = 0; fgc = 7; bgc = 0; bold = blink = inverse = 0; g0_dec = 0;
	autowrap = 1; cursor_visible = 1;
	if (mode == EMU_PETSCII) {
		fg = 1; bg = 0; rev = 0;
		scr_mode(40, 1, pal_c64);
		fg = 1;
	}
	else {
		colours();
		scr_mode(80, 0, pal_ansi);
	}
}

/* ------------------------------------------------------------- ANSI / VT100 */
static unsigned char p1(unsigned char i, unsigned char def)
{
	return (i < nparam && param[i]) ? param[i] : def;
}

static void reply(const char *s) { net_puts(s); }

static void reply_num(unsigned char n)
{
	if (n >= 10) net_put('0' + n / 10);
	net_put('0' + n % 10);
}

static void sgr(void)
{
	unsigned char i, v;
	if (nparam == 0) { param[0] = 0; nparam = 1; }
	for (i = 0; i < nparam; i++) {
		v = param[i];
		if (v == 0) { fgc = 7; bgc = 0; bold = blink = inverse = 0; }
		else if (v == 1) bold = 1;
		else if (v == 5 || v == 6) blink = 1;
		else if (v == 7) inverse = 1;
		else if (v == 22) bold = 0;
		else if (v == 25) blink = 0;
		else if (v == 27) inverse = 0;
		else if (v >= 30 && v <= 37) fgc = v - 30;
		else if (v == 39) fgc = 7;
		else if (v >= 40 && v <= 47) bgc = v - 40;
		else if (v == 49) bgc = 0;
		else if (v >= 90 && v <= 97) { fgc = v - 90; bold = 1; }
		else if (v >= 100 && v <= 107) { bgc = v - 100; blink = 1; }
	}
	colours();
}

static void clamp(void)
{
	if (cur_x >= cols) cur_x = cols - 1;
	if (cur_y >= ROWS) cur_y = ROWS - 1;
	wrap_pending = 0;
}

static void csi(unsigned char f)
{
	unsigned char n = p1(0, 1), y;
	switch (f) {
	case 'A': cur_y = (cur_y >= top_margin + n) ? cur_y - n : (cur_y >= top_margin ? top_margin : (cur_y >= n ? cur_y - n : 0)); break;
	case 'B': cur_y = (cur_y + n <= bot_margin) ? cur_y + n : bot_margin; break;
	case 'C': cur_x = (cur_x + n < cols) ? cur_x + n : cols - 1; break;
	case 'D': cur_x = (cur_x >= n) ? cur_x - n : 0; break;
	case 'E': cur_x = 0; cur_y = (cur_y + n <= bot_margin) ? cur_y + n : bot_margin; break;
	case 'F': cur_x = 0; cur_y = (cur_y >= n) ? cur_y - n : 0; break;
	case 'G': case '`': cur_x = n - 1; break;
	case 'd': cur_y = n - 1; break;
	case 'H': case 'f': cur_y = p1(0, 1) - 1; cur_x = p1(1, 1) - 1; break;
	case 'J':
		y = (nparam ? param[0] : 0);
		if (y == 0) { scr_clear_line(cur_y, cur_x, cols - 1); if (cur_y < ROWS - 1) scr_clear_rows(cur_y + 1, ROWS - 1); }
		else if (y == 1) { if (cur_y) scr_clear_rows(0, cur_y - 1); scr_clear_line(cur_y, 0, cur_x); }
		else { scr_clear_rows(0, ROWS - 1); if (emu == EMU_ANSI) cur_x = cur_y = 0; }
		break;
	case 'K':
		y = (nparam ? param[0] : 0);
		if (y == 0) scr_clear_line(cur_y, cur_x, cols - 1);
		else if (y == 1) scr_clear_line(cur_y, 0, cur_x);
		else scr_clear_line(cur_y, 0, cols - 1);
		break;
	case 'L': if (cur_y >= top_margin && cur_y <= bot_margin) scr_scroll(cur_y, bot_margin, n, 1); break;
	case 'M': if (cur_y >= top_margin && cur_y <= bot_margin) scr_scroll(cur_y, bot_margin, n, 0); break;
	case 'P': scr_insdel_char(n, 0); break;
	case '@': scr_insdel_char(n, 1); break;
	case 'X': scr_clear_line(cur_y, cur_x, (cur_x + n - 1 < cols) ? cur_x + n - 1 : cols - 1); break;
	case 'S': scr_scroll(top_margin, bot_margin, n, 0); break;
	case 'T': scr_scroll(top_margin, bot_margin, n, 1); break;
	case 'm': sgr(); break;
	case 'r':
		top_margin = p1(0, 1) - 1; bot_margin = p1(1, ROWS) - 1;
		if (bot_margin >= ROWS || top_margin >= bot_margin) { top_margin = 0; bot_margin = ROWS - 1; }
		cur_x = 0; cur_y = 0;
		break;
	case 's': save_x = cur_x; save_y = cur_y; break;
	case 'u': cur_x = save_x; cur_y = save_y; break;
	case 'n':
		if (p1(0, 0) == 6) { reply("\033["); reply_num(cur_y + 1); net_put(';'); reply_num(cur_x + 1); net_put('R'); }
		else if (p1(0, 0) == 5) reply("\033[0n");
		break;
	case 'c': reply("\033[?1;0c"); break;
	case 'h': case 'l':
		if (priv) {
			if (param[0] == 7) autowrap = (f == 'h');
			else if (param[0] == 25) cursor_visible = (f == 'h');
		}
		break;
	}
	clamp();
}

/* DEC special graphics $5F-$7E as CP437 glyphs */
static const unsigned char dec_gfx[32] = {
	' ', 0x04, 0xB1, 'H', 'F', 'C', 'L', 0xF8, 0xF1, 'N', 'V', 0xD9, 0xBF, 0xDA, 0xC0, 0xC5,
	0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC3, 0xB4, 0xC1, 0xC2, 0xB3, 0xF3, 0xF2, 0xE3, 0xD8, 0x9C, 0xF9
};

static void ansi_byte(unsigned char c)
{
	switch (state) {
	case 0:
		if (c == 27) { state = 1; return; }
		if (c == 13) { cur_x = 0; wrap_pending = 0; return; }
		if (c == 10 || c == 11) { scr_newline(); return; }
		if (c == 8) { if (cur_x) --cur_x; wrap_pending = 0; return; }
		if (c == 9) { cur_x = (cur_x | 7) + 1; if (cur_x >= cols) cur_x = cols - 1; return; }
		if (c == 12) { scr_cls(); return; }
		if (c == 7 || c == 0 || c == 14 || c == 15) return;
		if (emu == EMU_VT100) {
			if (c < 32 || c == 127) return;
			if (g0_dec && c >= 0x5F && c <= 0x7E) c = dec_gfx[c - 0x5F];
		}
		scr_put(c);
		return;
	case 1:                             /* after ESC */
		state = 0;
		if (c == '[') { state = 2; nparam = 0; priv = 0; param[0] = 0; return; }
		if (c == '(') { state = 3; return; }
		if (c == ')') { state = 4; return; }
		if (c == '7') { save_x = cur_x; save_y = cur_y; }
		else if (c == '8') { cur_x = save_x; cur_y = save_y; }
		else if (c == 'D') scr_newline();
		else if (c == 'E') { cur_x = 0; scr_newline(); }
		else if (c == 'M') { if (cur_y == top_margin) scr_scroll(top_margin, bot_margin, 1, 1); else if (cur_y) --cur_y; }
		else if (c == 'c') emu_start(emu);
		return;
	case 2:                             /* CSI parameters */
		if (c >= '0' && c <= '9') {
			if (nparam == 0) nparam = 1;
			param[nparam - 1] = param[nparam - 1] * 10 + (c - '0');
			return;
		}
		if (c == ';') { if (nparam == 0) nparam = 1; if (nparam < 8) param[nparam++] = 0; return; }
		if (c == '?' || c == '=' || c == '>') { priv = 1; return; }
		if (c >= 0x40 && c <= 0x7E) { state = 0; csi(c); return; }
		if (c < 0x20) { ansi_byte(c); state = 2; return; }
		return;
	case 3: g0_dec = (c == '0'); state = 0; return;
	case 4: state = 0; return;
	}
}

/* ------------------------------------------------------------------ PETSCII */
static unsigned char prvs;

static unsigned char pet_colour(unsigned char c)
{
	static const unsigned char codes[16] = { 144, 5, 28, 159, 156, 30, 31, 158, 129, 149, 150, 151, 152, 153, 154, 155 };
	unsigned char i;
	for (i = 0; i < 16; i++) if (codes[i] == c) return i;
	return 0xFF;
}

static void pet_byte(unsigned char c)
{
	unsigned char k = pet_colour(c);
	if (k != 0xFF) { fg = k; return; }
	switch (c) {
	case 13: case 141: cur_x = 0; prvs = 0; wrap_pending = 0; scr_newline(); return;
	case 17:  if (cur_y < ROWS - 1) ++cur_y; else scr_newline(); return;
	case 145: if (cur_y) --cur_y; return;
	case 29:  if (cur_x < cols - 1) ++cur_x; else { cur_x = 0; scr_newline(); } return;
	case 157: if (cur_x) --cur_x; else if (cur_y) { cur_x = cols - 1; --cur_y; } return;
	case 19:  cur_x = cur_y = 0; return;
	case 147: scr_cls(); return;
	case 18:  prvs = 1; return;
	case 146: prvs = 0; return;
	case 14:  scr_font = g_font = 2; return;
	case 142: scr_font = g_font = 1; return;
	case 20:  if (cur_x) { --cur_x; scr_insdel_char(1, 0); } return;
	case 148: scr_insdel_char(1, 1); return;
	}
	if (c < 32 || (c >= 128 && c < 160)) return;
	/* PETSCII to screen code */
	if (c < 0x40) ;
	else if (c < 0x60) c -= 0x40;
	else if (c < 0x80) c -= 0x20;
	else if (c < 0xC0) c -= 0x40;
	else if (c < 0xFF) c -= 0x80;
	else c = 0x5E;
	if (prvs) c |= 0x80;
	scr_put(c);
	if (wrap_pending) { wrap_pending = 0; cur_x = 0; scr_newline(); }
}

void emu_byte(unsigned char c)
{
	if (emu == EMU_PETSCII) pet_byte(c);
	else ansi_byte(c);
}

/* ------------------------------------------------------------------ keyboard */
void emu_key(unsigned char k)
{
	if (emu == EMU_PETSCII) { net_put(k); return; }
	switch (k) {
	case 145: net_puts("\033[A"); return;
	case 17:  net_puts("\033[B"); return;
	case 29:  net_puts("\033[C"); return;
	case 157: net_puts("\033[D"); return;
	case 19:  net_puts("\033[H"); return;
	case 147: net_puts("\033[F"); return;
	case 148: net_puts("\033[2~"); return;
	case 20:  net_put(8); return;
	case 13:  net_put(13); return;
	case 141: net_put(10); return;
	}
	if (k >= 0x41 && k <= 0x5A) k += 0x20;           /* unshifted letters */
	else if (k >= 0xC1 && k <= 0xDA) k -= 0x80;      /* shifted letters */
	else if (k == 0x5C) k = '\\';                    /* pound */
	else if (k == 0x5E) k = '^';
	else if (k == 0x5F) k = '_';
	else if (k == 0xA9) k = '|';
	else if (k >= 128) return;
	net_put(k);
}
