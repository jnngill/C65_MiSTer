/* C65TERM: a telnet BBS terminal for the C65 (and the C65 MiSTer core).
** Shared declarations.
*/
#ifndef TERM_H
#define TERM_H

/* hw.s: cell drawing, DMA, far memory, serial port */
extern unsigned char g_col, g_row, g_ch, g_fg, g_bg, g_attr, g_font, g_cols;
extern unsigned char g_top, g_bot, g_dir, g_lines;
extern unsigned long g_far, g_copydst;
void hw_draw(void);
void hw_scroll(void);
void hw_clear_rows(void);
void hw_video_on(void);
void hw_video_off(void);
void __fastcall__ hw_set_palette(const unsigned char *rgb);
void __fastcall__ hw_shadow_put(unsigned char attr);
unsigned char hw_shadow_get(void);
unsigned char far_get(void);
void __fastcall__ far_put(unsigned char b);
void __fastcall__ hw_fill_far(unsigned int count);
void __fastcall__ hw_copy_far(unsigned int count);
void ser_init(void);
void ser_off(void);
int ser_get(void);
void __fastcall__ ser_put(unsigned char b);
unsigned int ser_avail(void);
void __fastcall__ ser_baud(unsigned int divisor);

void setbnk0(void);

/* sysmap.s */
void sysexit(void);                            /* restart the machine, does not return */

/* font.c */
void font_build(void);

/* screen.c: the 25 row terminal screen */
#define ROWS 25
extern unsigned char cols, cur_x, cur_y, fg, bg, rev, scr_font;
extern unsigned char top_margin, bot_margin, wrap_pending, autowrap;
void scr_mode(unsigned char ncols, unsigned char font, const unsigned char *pal);
void scr_cls(void);
void scr_put(unsigned char ch);                /* at the cursor, advancing */
void scr_cell(unsigned char x, unsigned char y, unsigned char ch);
void scr_newline(void);                        /* line feed with scrolling */
void scr_scroll(unsigned char top, unsigned char bot, unsigned char n, unsigned char down);
void scr_clear_line(unsigned char y, unsigned char from, unsigned char to);
void scr_clear_rows(unsigned char from, unsigned char to);
void scr_cursor(unsigned char on);
void scr_insdel_char(unsigned char n, unsigned char insert);
void scr_print(unsigned char x, unsigned char y, const char *s);   /* ASCII, font 0 */
void scr_status(const char *s);

/* serial.c: telnet layer on top of the serial port */
extern unsigned char telnet;
int net_get(void);
void net_put(unsigned char b);
void net_puts(const char *s);
void net_flush_in(void);
unsigned int ticks(void);                      /* 1/10 s */

/* emu.c: ANSI / VT100 / PETSCII */
#define EMU_ANSI    0
#define EMU_VT100   1
#define EMU_PETSCII 2
extern unsigned char emu;
void emu_start(unsigned char mode);
void emu_byte(unsigned char c);
void emu_key(unsigned char k);                 /* a key from the keyboard */

/* xfer.c */
extern unsigned char zm_detect;
void xfer_menu(unsigned char download);
void zm_receive(void);

/* ui.c */
void ui_message(const char *s);
unsigned char ui_input(unsigned char x, unsigned char y, char *buf, unsigned char max);
unsigned char ui_key(void);
void wait_key(void);

#endif
