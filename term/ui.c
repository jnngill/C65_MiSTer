/* C65TERM user interface: dialling directory, modem, session loop.
**
** The C65's serial port is connected to the MiSTer's emulated modem
** (midilink): "ATDT host:port" opens a telnet connection.
*/
#include "ascii.h"
#include <cbm.h>
#include <string.h>
#include "term.h"

#define VERSION "C65TERM 1.0"
#define MAXSITES 8
#define CFGFILE "0:C65TERM.CFG"

struct site { char name[20]; char addr[40]; unsigned char emu; };
/* the directory lives in the text screen RAM at $0C00 (unused while the
** terminal runs; see hw.s / sysmap.s for the rest of $0800-$0FFF) */
static struct site *const sites = (struct site *)0x0C00;
static unsigned char nsites;
static unsigned char baud_sel = 1;                /* 2400, 9600, 19200 */
static const unsigned int baud_div[3] = { 184, 45, 22 };
static const char *const baud_name[3] = { "2400", "9600", "19200" };
static const char emu_letter[3] = { 'a', 'v', 'p' };
static const char *const emu_name[3] = { "ANSI", "VT100", "PETSCII" };
static char line[82];

/* ------------------------------------------------------------------ input */
unsigned char ui_key(void)
{
	unsigned char k;
	while ((k = cbm_k_getin()) == 0) ;
	if (k >= 0x41 && k <= 0x5A) k += 0x20;
	else if (k >= 0xC1 && k <= 0xDA) k -= 0x80;
	return k;
}

void wait_key(void) { ui_key(); }

void ui_message(const char *s)
{
	strcpy(line, s);
	strcat(line, " - press a key");
	scr_status(line);
	ui_key();
	scr_status("");
}

/* edit an ASCII line at (x, y); 1 = RETURN, 0 = RUN/STOP */
unsigned char ui_input(unsigned char x, unsigned char y, char *b, unsigned char max)
{
	unsigned char n = (unsigned char)strlen(b), k, i;
	for (;;) {
		for (i = 0; i <= max && x + i < cols; i++) scr_cell(x + i, y, ' ');
		scr_print(x, y, b);
		k = ui_key();
		if (k == 13) return n != 0;
		if (k == 3) return 0;
		if (k == 20) { if (n) b[--n] = 0; continue; }
		if (k >= 32 && k < 127 && n < max) { b[n++] = k; b[n] = 0; }
	}
}

/* ------------------------------------------------------------------ sites */
static void add_site(const char *name, const char *addr, unsigned char e)
{
	if (nsites == MAXSITES) return;
	strncpy(sites[nsites].name, name, 19);
	strncpy(sites[nsites].addr, addr, 39);
	sites[nsites].emu = e;
	++nsites;
}

static void load_sites(void)
{
	int n;
	unsigned char i, f;
	nsites = 0;
	setbnk0();
	if (cbm_open(6, 8, CBM_READ, CFGFILE ",S") != 0) goto defaults;
	/* one site per line: name|address|a,v or p */
	for (;;) {
		i = 0;
		for (;;) {
			n = cbm_read(6, line + i, 1);
			if (n != 1) break;
			if (line[i] == 13 || line[i] == 10) break;
			if (i < 80) ++i;
		}
		line[i] = 0;
		if (i) {
			char *a = strchr(line, '|'), *b;
			f = EMU_ANSI;
			if (a) {
				*a++ = 0; b = strchr(a, '|');
				if (b) { *b++ = 0; f = (*b == 'p') ? EMU_PETSCII : (*b == 'v') ? EMU_VT100 : EMU_ANSI; }
				add_site(line, a, f);
			}
		}
		if (n != 1) break;
	}
	cbm_close(6);
	if (nsites) return;
defaults:
	add_site("Synchronet (vert)", "vert.synchro.net:23", EMU_ANSI);
	add_site("Black Flag", "blackflag.acid.org:23", EMU_ANSI);
	add_site("Particles BBS", "particlesbbs.dyndns.org:6400", EMU_PETSCII);
}

static void save_sites(void)
{
	unsigned char i;
	setbnk0();
	cbm_open(15, 8, 15, "S0:C65TERM.CFG");          /* scratch the old file */
	cbm_close(15);
	if (cbm_open(6, 8, CBM_WRITE, CFGFILE ",S,W") != 0) { ui_message("cannot write c65term.cfg"); return; }
	for (i = 0; i < nsites; i++) {
		strcpy(line, sites[i].name); strcat(line, "|");
		strcat(line, sites[i].addr); strcat(line, "|");
		line[strlen(line) + 1] = 0; line[strlen(line)] = emu_letter[sites[i].emu];
		strcat(line, "\r");
		cbm_write(6, line, strlen(line));
	}
	cbm_close(6);
}

/* ------------------------------------------------------------------ modem */
static void delay(unsigned char tenths)
{
	unsigned int t = ticks();
	while ((unsigned int)(ticks() - t) < tenths) ;
}

static void modem_cmd(const char *s)
{
	telnet = 0;
	net_puts(s);
	net_put(13);
	delay(5);
	net_flush_in();
}

static void hang_up(void)
{
	telnet = 0;
	delay(12);
	net_puts("+++");
	delay(12);
	modem_cmd("ATH");
}

static void set_baud(unsigned char sel)
{
	strcpy(line, "ATBAUD");
	strcat(line, baud_name[sel]);
	modem_cmd(line);
	delay(30);                          /* midilink switches after a moment */
	baud_sel = sel;
	ser_baud(baud_div[sel]);
}

/* show modem output until CONNECT (1), NO CARRIER / BUSY / ERROR (0) or a key */
static unsigned char wait_connect(void)
{
	unsigned char n = 0, k;
	int c;
	unsigned int start = ticks();
	for (;;) {
		c = net_get();
		if (c >= 0) {
			if (c == 13 || c == 10) {
				line[n] = 0;
				if (n) scr_status(line);
				if (strncmp(line, "CONNECT", 7) == 0) return 1;
				if (strncmp(line, "NO CARRIER", 10) == 0 || strncmp(line, "BUSY", 4) == 0 ||
				    strncmp(line, "ERROR", 5) == 0 || strncmp(line, "NO ANSWER", 9) == 0) { delay(15); return 0; }
				n = 0;
			}
			else if (n < 80) line[n++] = (char)c;
		}
		k = cbm_k_getin();
		if (k == 3) return 0;
		if ((unsigned int)(ticks() - start) > 600) return 0;
	}
}

/* ------------------------------------------------------------------ session */
static void session(unsigned char e)
{
	int c;
	unsigned char k, zm = 0, i;
	static const char zrq[] = "**\030B00";
	emu_start(e);
	scr_cursor(1);
	for (;;) {
		/* incoming data first, a screenful at a time */
		for (i = 0; i < 200; i++) {
			c = net_get();
			if (c < 0) break;
			if (i == 0) scr_cursor(0);
			/* ZMODEM download starting: "**", ZDLE, "B00" */
			if ((char)c == zrq[zm]) { if (++zm == 6) { zm = 0; zm_receive(); emu_start(emu); break; } }
			else zm = ((char)c == '*') ? 1 : 0;
			emu_byte((unsigned char)c);
		}
		scr_cursor(1);
		k = cbm_k_getin();
		if (k == 0) continue;
		if (k == 133) {                                  /* F1: session menu */
			scr_cursor(0);
			scr_status("F1 menu:  H hang up  D download  U upload  E emulation  RETURN back");
			k = ui_key();
			if (k == 'h') { hang_up(); return; }
			if (k == 'd') xfer_menu(1);
			else if (k == 'u') xfer_menu(0);
			else if (k == 'e') { emu_start((emu + 1) % 3); continue; }
			scr_clear_line(ROWS - 1, 0, cols - 1);
			scr_cursor(1);
			continue;
		}
		scr_cursor(0);
		emu_key(k);
		scr_cursor(1);
	}
}

static void dial(const char *addr, unsigned char e)
{
	modem_cmd("ATTEL0");
	strcpy(line, "ATDT");
	strcat(line, addr);
	scr_status(line);
	telnet = 0;
	net_flush_in();
	net_puts(line);
	net_put(13);
	if (!wait_connect()) { ui_message("no connection"); return; }
	telnet = 2;                         /* telnet if the server negotiates */
	session(e);
}

/* type straight to the modem (AT commands) */
static void direct(void)
{
	int c;
	unsigned char k;
	emu_start(EMU_ANSI);
	telnet = 0;
	scr_status("direct to the modem - F1 returns");
	cur_y = 1;
	for (;;) {
		while ((c = net_get()) >= 0) emu_byte((unsigned char)c);
		k = cbm_k_getin();
		if (k == 133) return;
		if (k) emu_key(k);
	}
}

/* ------------------------------------------------------------------ main menu */
static void menu_screen(void)
{
	unsigned char i;
	emu_start(EMU_ANSI);
	fg = 14; scr_print(2, 1, VERSION);
	fg = 7;  scr_print(2, 2, "Telnet BBS terminal: ANSI, VT100, PETSCII, XMODEM and ZMODEM");
	fg = 11; scr_print(2, 4, "Dialling directory");
	fg = 7;
	for (i = 0; i < nsites; i++) {
		line[0] = '1' + i; line[1] = ' '; line[2] = ' '; line[3] = 0;
		strcat(line, sites[i].name);
		scr_print(4, 6 + i, line);
		scr_print(30, 6 + i, sites[i].addr);
		scr_print(66, 6 + i, emu_name[sites[i].emu]);
	}
	fg = 11;
	scr_print(2, 17, "1-8 dial   Q quick dial   A add   D delete   M modem   B baud   X exit");
	fg = 7;
	strcpy(line, "baud ");
	strcat(line, baud_name[baud_sel]);
	strcat(line, "  (set the MiSTer's UART to the same speed)");
	scr_print(2, 19, line);
}

static unsigned char ask_emu(void)
{
	unsigned char k;
	scr_status("emulation: A = ANSI  V = VT100  P = PETSCII");
	k = ui_key();
	return (k == 'p') ? EMU_PETSCII : (k == 'v') ? EMU_VT100 : EMU_ANSI;
}

int main(void)
{
	unsigned char k, e;
	static char addr[40], name[20];

	/* start the CIA time-of-day clock (50 Hz on PAL) */
	*(unsigned char *)0xDC0E |= 0x80;
	*(unsigned char *)0xDC0B = 0; *(unsigned char *)0xDC0A = 0;
	*(unsigned char *)0xDC09 = 0; *(unsigned char *)0xDC08 = 0;

	font_build();
	ser_init();
	ser_baud(baud_div[baud_sel]);
	load_sites();
	for (;;) {
		menu_screen();
		k = ui_key();
		if (k >= '1' && k < '1' + nsites) dial(sites[k - '1'].addr, sites[k - '1'].emu);
		else if (k == 'q') {
			addr[0] = 0;
			scr_status("host:port ");
			if (ui_input(10, ROWS - 1, addr, 38)) { e = ask_emu(); dial(addr, e); }
		}
		else if (k == 'a' && nsites < MAXSITES) {
			name[0] = 0; addr[0] = 0;
			scr_status("name ");
			if (ui_input(5, ROWS - 1, name, 18)) {
				scr_status("host:port ");
				if (ui_input(10, ROWS - 1, addr, 38)) { add_site(name, addr, ask_emu()); save_sites(); }
			}
		}
		else if (k == 'd' && nsites) {
			scr_status("delete which entry (1-8)? ");
			k = ui_key();
			if (k >= '1' && k < '1' + nsites) {
				for (e = k - '1'; e + 1 < nsites; e++) sites[e] = sites[e + 1];
				--nsites;
				save_sites();
			}
		}
		else if (k == 'm') direct();
		else if (k == 'b') set_baud((baud_sel + 1) % 3);
		else if (k == 'x') break;
	}
	ser_off();
	hw_video_off();
	sysexit();
	return 0;
}
