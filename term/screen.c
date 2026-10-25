/* The terminal screen: 25 rows of 40 or 80 cells on the bitplane picture,
** with a shadow copy of every cell (glyph, colours) for the cursor and for
** inserting / deleting characters.
*/
#include "ascii.h"
#include "term.h"

unsigned char cols = 80, cur_x, cur_y, fg = 7, bg, rev, scr_font;
unsigned char top_margin, bot_margin = ROWS - 1, wrap_pending, autowrap = 1;
static unsigned char cursor_on;

static void draw(unsigned char x, unsigned char y, unsigned char ch, unsigned char f, unsigned char b)
{
	g_col = x; g_row = y; g_ch = ch; g_fg = f; g_bg = b; g_attr = 0;
	hw_draw();
	g_col = x; g_row = y; g_ch = ch;
	hw_shadow_put((unsigned char)(f | (b << 4)));
}

void scr_cell(unsigned char x, unsigned char y, unsigned char ch)
{
	if (rev) draw(x, y, ch, bg, fg);
	else     draw(x, y, ch, fg, bg);
}

void scr_mode(unsigned char ncols, unsigned char font, const unsigned char *pal)
{
	cols = ncols; scr_font = font;
	g_cols = ncols; g_font = font;
	hw_video_on();
	hw_set_palette(pal);
	top_margin = 0; bot_margin = ROWS - 1;
	scr_cls();
}

void scr_clear_rows(unsigned char from, unsigned char to)
{
	g_top = from; g_lines = to - from + 1; g_fg = fg; g_bg = bg; g_cols = cols;
	hw_clear_rows();
}

void scr_cls(void)
{
	scr_clear_rows(0, ROWS - 1);
	cur_x = cur_y = 0; wrap_pending = 0;
}

void scr_clear_line(unsigned char y, unsigned char from, unsigned char to)
{
	unsigned char x;
	if (from == 0 && to >= cols - 1) { scr_clear_rows(y, y); return; }
	for (x = from; x <= to && x < cols; x++) draw(x, y, ' ', fg, bg);
}

void scr_scroll(unsigned char top, unsigned char bot, unsigned char n, unsigned char down)
{
	if (n > bot - top + 1) n = bot - top + 1;
	g_top = top; g_bot = bot; g_lines = n; g_dir = down; g_fg = fg; g_bg = bg; g_cols = cols;
	hw_scroll();
}

void scr_newline(void)
{
	wrap_pending = 0;
	if (cur_y == bot_margin) scr_scroll(top_margin, bot_margin, 1, 0);
	else if (cur_y < ROWS - 1) ++cur_y;
}

/* write at the cursor; the cursor stops on the last column and wraps when
** the next character comes (as VT100 / ANSI-BBS terminals do) */
void scr_put(unsigned char ch)
{
	if (wrap_pending) {
		if (autowrap) { cur_x = 0; scr_newline(); }
		wrap_pending = 0;
	}
	scr_cell(cur_x, cur_y, ch);
	if (cur_x < cols - 1) ++cur_x;
	else wrap_pending = 1;
}

void scr_insdel_char(unsigned char n, unsigned char insert)
{
	unsigned char x, a, last = cols - 1;
	if (insert) {
		for (x = last; x >= cur_x + n && x != 0xFF; x--) {
			g_col = x - n; g_row = cur_y; a = hw_shadow_get();
			draw(x, cur_y, g_ch, a & 15, a >> 4);
			if (x == 0) break;
		}
		for (x = cur_x; x < cur_x + n && x <= last; x++) draw(x, cur_y, ' ', fg, bg);
	}
	else {
		for (x = cur_x; x + n <= last; x++) {
			g_col = x + n; g_row = cur_y; a = hw_shadow_get();
			draw(x, cur_y, g_ch, a & 15, a >> 4);
		}
		for (; x <= last; x++) draw(x, cur_y, ' ', fg, bg);
	}
}

/* the cursor is the cell drawn with its colours swapped */
void scr_cursor(unsigned char on)
{
	unsigned char a;
	if (on == cursor_on) return;
	cursor_on = on;
	g_col = cur_x; g_row = cur_y; a = hw_shadow_get();
	g_col = cur_x; g_row = cur_y; g_fg = on ? a >> 4 : a & 15; g_bg = on ? a & 15 : a >> 4;
	if (on && g_fg == g_bg) g_bg = 7;
	g_attr = 0;
	hw_draw();
}

/* text for menus and the status line: ASCII in font 0 (CP437) or the
** PETSCII font, wherever the cursor is not */
void scr_print(unsigned char x, unsigned char y, const char *s)
{
	unsigned char c;
	while ((c = (unsigned char)*s++) != 0 && x < cols) {
		if (scr_font) {
			/* ASCII to C64 screen code */
			if (c >= 'a' && c <= 'z') c -= (scr_font == 2) ? 0x60 : 0x60;
			else if (c >= 'A' && c <= 'Z') c = (scr_font == 2) ? c : c - 0x40;
			else if (c == '@') c = 0;
			else if (c >= 0x5B && c <= 0x5F) c -= 0x40;
		}
		scr_cell(x++, y, c);
	}
}

void scr_status(const char *s)
{
	unsigned char of = fg, ob = bg, x;
	fg = 0; bg = 7;
	scr_print(0, ROWS - 1, s);
	for (x = 0; s[x]; x++) ;
	for (; x < cols; x++) scr_cell(x, ROWS - 1, ' ');
	fg = of; bg = ob;
}
