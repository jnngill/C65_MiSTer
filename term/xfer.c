/* File transfers to and from drive 8: XMODEM (checksum, CRC, 1K) and
** ZMODEM (CRC-16 headers and data; the receiver asks for a 1K window, so
** the sender waits for an ACK while each kilobyte is written to disk).
*/
#include "ascii.h"
#include <cbm.h>
#include <string.h>
#include "term.h"

#define SOH 1
#define STX 2
#define EOT 4
#define ACK 6
#define NAK 21
#define CAN 24

#define ZPAD  '*'
#define ZDLE  24
#define ZBIN  'A'
#define ZHEX  'B'
#define ZRQINIT 0
#define ZRINIT  1
#define ZSINIT  2
#define ZACK    3
#define ZFILE   4
#define ZSKIP   5
#define ZNAK    6
#define ZABORT  7
#define ZFIN    8
#define ZRPOS   9
#define ZDATA   10
#define ZEOF    11
#define ZCRCE 'h'
#define ZCRCG 'i'
#define ZCRCQ 'j'
#define ZCRCW 'k'
#define GOTCRC 0x100            /* zdl_get: frame end seen (low byte = which) */
#define TIMEOUT -2

#define LFN 5                   /* KERNAL file number for transfers */

unsigned char zm_detect;
static unsigned char buf[1024];
static unsigned int crc;
static unsigned char hdr[4];
static unsigned long fpos;
static char fname[20];
static unsigned char aborted;
static const char *why;             /* reason for the last cancel */

/* "transfer cancelled: <why>, <n> bytes" */
static void cancelled(unsigned long n)
{
	static char m[70];
	char d[12];
	unsigned char i = 0;
	strcpy(m, "transfer cancelled: ");
	strcat(m, aborted ? "RUN/STOP" : why);
	strcat(m, ", ");
	do { d[i++] = '0' + (unsigned char)(n % 10); n /= 10; } while (n && i < 11);
	{ unsigned char j = (unsigned char)strlen(m); while (i) m[j++] = d[--i]; m[j] = 0; }
	strcat(m, " bytes");
	ui_message(m);
}

/* ------------------------------------------------------------------ helpers */
static void crc_byte(unsigned char b)
{
	unsigned char i;
	crc ^= (unsigned int)b << 8;
	for (i = 0; i < 8; i++)
		crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : (crc << 1);
}

/* a byte within t tenths of a second, or TIMEOUT; RUN/STOP aborts */
static int rx(unsigned int t)
{
	unsigned int start = ticks(), now;
	int c;
	for (;;) {
		c = net_get();
		if (c >= 0) return c;
		if (cbm_k_getin() == 3) { aborted = 1; return TIMEOUT; }
		now = ticks();
		if ((unsigned int)(now - start) >= t && now >= start) return TIMEOUT;
		if (now < start && now + 36000u - start >= t) return TIMEOUT;
	}
}

static void show(const char *what, unsigned long n)
{
	static char line[60];
	char num[12];
	unsigned char i = 0;
	strcpy(line, what);
	strcat(line, "  ");
	strcat(line, fname);
	strcat(line, "  ");
	do { num[i++] = '0' + (unsigned char)(n % 10); n /= 10; } while (n && i < 11);
	while (i) { char d[2]; d[0] = num[--i]; d[1] = 0; strcat(line, d); }
	strcat(line, cols < 80 ? " bytes" : " bytes   (RUN/STOP cancels)");
	scr_status(line);
}

/* ASCII file name to a PETSCII disk name */
static void disk_name(char *out, const char *in, const char *mode)
{
	unsigned char i = 0;
	char c;
	out[i++] = '0'; out[i++] = ':';
	while ((c = *in++) != 0 && i < 18) {
		if (c >= 'a' && c <= 'z') c -= 0x20;
		else if (c == '/' || c == ':' || c == ',' || c == '*' || c == '?') c = '-';
		out[i++] = c;
	}
	out[i] = 0;
	strcat(out, mode);
}

/* the drive's error channel, shown on the status line, e.g. "26,write protect on" */
static void disk_error(void)
{
	static char msg[48];
	int n;
	setbnk0();
	if (cbm_open(15, 8, 15, "") != 0) { ui_message("disk error (no status)"); return; }
	strcpy(msg, "disk error ");
	n = cbm_read(15, msg + 11, 30);
	cbm_close(15);
	if (n > 0) { msg[11 + n] = 0; if (msg[10 + n] == 13) msg[10 + n] = 0; }
	ui_message(msg);
}

/* write the buffer; 0 (and the drive's message shown) if it failed */
static unsigned char disk_write(unsigned int len)
{
	if (cbm_write(LFN, buf, len) == (int)len) return 1;
	disk_error();
	return 0;
}

static unsigned char open_out(void)
{
	char n[32];
	disk_name(n, fname, ",S,W");
	setbnk0();
	return cbm_open(LFN, 8, CBM_WRITE, n) == 0;
}

static unsigned char open_in(void)
{
	char n[32];
	disk_name(n, fname, ",R");
	setbnk0();
	if (cbm_open(LFN, 8, CBM_READ, n) != 0) return 0;
	return 1;
}

/* ------------------------------------------------------------------ XMODEM */
static void x_receive(void)
{
	unsigned char blk = 1, b, crcmode = 1, tries = 0, sum, i, bad = 0;
	unsigned int len, n;
	int c;
	unsigned long total = 0;
	if (!open_out()) { ui_message("cannot create the file"); return; }
	net_flush_in();
	for (;;) {
		net_put(crcmode ? 'C' : NAK);
		c = rx(30);
		if (c == SOH || c == STX || c == EOT) break;
		why = "no data from the sender";
		if (aborted || ++tries == 10) goto fail;
		if (tries == 4) crcmode = 0;
	}
	for (;;) {
		if (c == EOT) { net_put(ACK); break; }
		if (c == CAN) { why = "the sender cancelled"; goto fail; }
		if (c != SOH && c != STX) { net_put(NAK); goto next; }
		len = (c == STX) ? 1024 : 128;
		c = rx(30); if (c < 0) goto bad; b = (unsigned char)c;
		c = rx(30); if (c < 0) goto bad;
		if ((unsigned char)~c != b) goto bad;
		crc = 0; sum = 0;
		for (n = 0; n < len; n++) {
			c = rx(30); if (c < 0) goto bad;
			buf[n] = (unsigned char)c; crc_byte((unsigned char)c); sum += (unsigned char)c;
		}
		if (crcmode) {
			c = rx(30); if (c < 0) goto bad; i = (unsigned char)c;
			c = rx(30); if (c < 0) goto bad;
			if (crc != (((unsigned int)i << 8) | (unsigned char)c)) goto bad;
		}
		else {
			c = rx(30); if (c < 0 || (unsigned char)c != sum) goto bad;
		}
		bad = 0;
		if (b == blk) {
			if (!disk_write(len)) { cbm_close(LFN); return; }
			total += len; ++blk;
			show("XMODEM receive", total);
		}
		net_put(ACK);
		goto next;
bad:
		why = "too many bad blocks";
		if (aborted || ++bad > 10) goto fail;
		net_flush_in();
		net_put(NAK);
next:
		/* the next block; on silence ask again (up to 10 times) */
		tries = 0;
		while ((c = rx(100)) < 0) {
			why = "timed out";
			if (aborted || ++tries > 10) goto fail;
			net_put(NAK);
		}
	}
	cbm_close(LFN);
	ui_message("download complete");
	return;
fail:
	net_put(CAN); net_put(CAN); net_put(CAN);
	cbm_close(LFN);
	cancelled(total);
}

static void x_send(void)
{
	unsigned char blk = 1, crcmode, tries, sum;
	unsigned int len, n, got;
	int c;
	unsigned long total = 0;
	if (!open_in()) { ui_message("file not found"); return; }
	net_flush_in();
	/* the receiver starts with C (CRC, 1K allowed) or NAK (checksum, 128) */
	for (tries = 0;; ) {
		c = rx(100);
		if (c == 'C') { crcmode = 1; break; }
		if (c == NAK) { crcmode = 0; break; }
		if (c == CAN || aborted || ++tries == 6) goto fail;
	}
	len = crcmode ? 1024 : 128;
	for (;;) {
		got = cbm_read(LFN, buf, len);
		if (got == 0 || got > len) break;
		for (n = got; n < len; n++) buf[n] = 26;
		for (tries = 0;; ) {
			net_put(len == 1024 ? STX : SOH);
			net_put(blk); net_put((unsigned char)~blk);
			crc = 0; sum = 0;
			for (n = 0; n < len; n++) { net_put(buf[n]); crc_byte(buf[n]); sum += buf[n]; }
			if (crcmode) { net_put((unsigned char)(crc >> 8)); net_put((unsigned char)crc); }
			else net_put(sum);
			c = rx(100);
			if (c == ACK) break;
			if (c == CAN || aborted || ++tries == 10) goto fail;
		}
		++blk; total += got;
		show("XMODEM send", total);
		if (got < len) break;
	}
	for (tries = 0; tries < 10; tries++) {
		net_put(EOT);
		if (rx(100) == ACK) break;
	}
	cbm_close(LFN);
	ui_message("upload complete");
	return;
fail:
	cbm_close(LFN);
	ui_message("transfer cancelled");
}

/* ------------------------------------------------------------------ ZMODEM */
static const char hexd[] = "0123456789abcdef";

static void hex_byte(unsigned char b)
{
	ser_put(hexd[b >> 4]); ser_put(hexd[b & 15]);
}

static void z_hexhdr(unsigned char type)
{
	unsigned char i;
	ser_put(ZPAD); ser_put(ZPAD); ser_put(ZDLE); ser_put(ZHEX);
	crc = 0;
	hex_byte(type); crc_byte(type);
	for (i = 0; i < 4; i++) { hex_byte(hdr[i]); crc_byte(hdr[i]); }

	hex_byte((unsigned char)(crc >> 8)); hex_byte((unsigned char)crc);
	ser_put(13); ser_put(10 | 0x80);
	if (type != ZFIN && type != ZACK) ser_put(17);
}

static void zdl_put(unsigned char c)
{
	switch (c) {
	case ZDLE: case 0x10: case 0x11: case 0x13: case 0x90: case 0x91: case 0x93: case 0x0D: case 0x8D:
		net_put(ZDLE); net_put(c ^ 0x40); return;
	}
	net_put(c);
}

static void z_binhdr(unsigned char type)
{
	unsigned char i;
	net_put(ZPAD); net_put(ZDLE); net_put(ZBIN);
	crc = 0;
	zdl_put(type); crc_byte(type);
	for (i = 0; i < 4; i++) { zdl_put(hdr[i]); crc_byte(hdr[i]); }

	zdl_put((unsigned char)(crc >> 8)); zdl_put((unsigned char)crc);
}

static void set_pos(unsigned long p)
{
	hdr[0] = (unsigned char)p; hdr[1] = (unsigned char)(p >> 8);
	hdr[2] = (unsigned char)(p >> 16); hdr[3] = (unsigned char)(p >> 24);
}

static unsigned long get_pos(void)
{
	return hdr[0] | ((unsigned int)hdr[1] << 8) | ((unsigned long)hdr[2] << 16) | ((unsigned long)hdr[3] << 24);
}

/* a ZDLE-decoded byte; frame ends come back as GOTCRC | char */
static int zdl_get(void)
{
	int c;
	unsigned char cans = 0;
	for (;;) {
		c = rx(100);
		if (c < 0) return c;
		if (c == 0x11 || c == 0x13 || c == 0x91 || c == 0x93) continue;   /* XON / XOFF */
		if (c != ZDLE) return c;
		for (;;) {
			c = rx(100);
			if (c < 0) return c;
			if (c == CAN) { if (++cans >= 4) { aborted = 1; return TIMEOUT; } continue; }
			break;
		}
		if (c >= ZCRCE && c <= ZCRCW) return GOTCRC | c;
		if (c == 'l') return 0x7F;
		if (c == 'm') return 0xFF;
		if (c == 0x11 || c == 0x13 || c == 0x91 || c == 0x93) continue;
		return c ^ 0x40;
	}
}

static int hex_get(void)
{
	int a, b;
	a = rx(100); if (a < 0) return a;
	b = rx(100); if (b < 0) return b;
	a = (a <= '9') ? a - '0' : (a | 0x20) - 'a' + 10;
	b = (b <= '9') ? b - '0' : (b | 0x20) - 'a' + 10;
	return (a << 4) | b;
}

/* the next header: its type, or TIMEOUT / -3 for a bad CRC */
static int z_gethdr(void)
{
	int c, t;
	unsigned char i, n = 0, form;
	for (;;) {
		c = rx(100);
		if (c < 0) return c;
		if (c == ZPAD) { n = 1; continue; }
		if (c == ZDLE && n) break;
		if (c == CAN && ++n > 5) { aborted = 1; return TIMEOUT; }
		if (c != ZPAD && c != CAN) n = 0;
	}
	c = rx(100);
	if (c < 0) return c;
	form = (unsigned char)c;
	crc = 0;
	if (form == ZHEX) {
		t = hex_get(); if (t < 0) return t; crc_byte((unsigned char)t);
		for (i = 0; i < 4; i++) { c = hex_get(); if (c < 0) return c; hdr[i] = (unsigned char)c; crc_byte(hdr[i]); }
		c = hex_get(); if (c < 0) return c; crc_byte((unsigned char)c);
		c = hex_get(); if (c < 0) return c; crc_byte((unsigned char)c);
		rx(2); rx(2);                       /* CR LF (XON) */
	}
	else if (form == ZBIN) {
		t = zdl_get(); if (t < 0 || t > 255) return -3; crc_byte((unsigned char)t);
		for (i = 0; i < 4; i++) { c = zdl_get(); if (c < 0 || c > 255) return -3; hdr[i] = (unsigned char)c; crc_byte(hdr[i]); }
		c = zdl_get(); if (c < 0 || c > 255) return -3; crc_byte((unsigned char)c);
		c = zdl_get(); if (c < 0 || c > 255) return -3; crc_byte((unsigned char)c);
	}
	else return -3;                          /* CRC-32 headers are not asked for */
	return crc ? -3 : t;
}

/* a data subpacket into buf: its length, frame end in *end; -1 on error */
static int z_getdata(unsigned char *end)
{
	unsigned int n = 0;
	int c;
	crc = 0;
	for (;;) {
		c = zdl_get();
		if (c < 0) return -1;
		if (c & GOTCRC) {
			*end = (unsigned char)c;
			crc_byte((unsigned char)c);
			c = zdl_get(); if (c < 0 || c > 255) return -1; crc_byte((unsigned char)c);
			c = zdl_get(); if (c < 0 || c > 255) return -1; crc_byte((unsigned char)c);
			return crc ? -1 : (int)n;
		}
		crc_byte((unsigned char)c);
		if (n < sizeof(buf)) buf[n++] = (unsigned char)c;
	}
}

static void z_rinit(void)
{
	hdr[0] = 0x00; hdr[1] = 0x04;            /* receive buffer: 1024 bytes */
	hdr[2] = 0; hdr[3] = 0x01;               /* CANFDX */
	z_hexhdr(ZRINIT);
}

#ifdef ZDEBUG
static char dbg[80];
static unsigned char dbgn;
static void dbg_add(char tag, int v)
{
	if (dbgn > 70) dbgn = 0;
	dbg[dbgn++] = tag;
	dbg[dbgn++] = hexd[(v >> 4) & 15]; dbg[dbgn++] = hexd[v & 15]; dbg[dbgn++] = ' ';
	dbg[dbgn] = 0;
	scr_status(dbg);
}
#else
#define dbg_add(a, b)
#endif

void zm_receive(void)
{
	int t, n;
	unsigned char end, open = 0, tries = 0, i;
	aborted = 0; fpos = 0;
	z_rinit();
	for (;;) {
		t = z_gethdr();
		dbg_add('h', t);
		if (aborted) goto fail;
		if (t < 0) {
			if (++tries > 10) goto fail;
			if (open) { set_pos(fpos); z_hexhdr(ZRPOS); } else z_rinit();
			continue;
		}
		tries = 0;
		switch (t) {
		case ZRQINIT: z_rinit(); break;
		case ZSINIT:
			z_getdata(&end); set_pos(0); z_hexhdr(ZACK); break;
		case ZFILE:
			n = z_getdata(&end);
			dbg_add('d', n);
			if (n <= 0) { z_rinit(); break; }
			buf[n < 1023 ? n : 1023] = 0;
			for (i = 0; i < sizeof(fname) - 1 && buf[i]; i++) fname[i] = buf[i];
			fname[i] = 0;
			if (open) cbm_close(LFN);
			open = open_out();
			if (!open) { z_hexhdr(ZSKIP); break; }
			fpos = 0; set_pos(0); z_hexhdr(ZRPOS);
			break;
		case ZDATA:
			if (!open || get_pos() != fpos) { set_pos(fpos); z_hexhdr(ZRPOS); break; }
			for (;;) {
				n = z_getdata(&end);
				if (n < 0) {
					if (aborted) goto fail;
					net_flush_in(); set_pos(fpos); z_hexhdr(ZRPOS);
					break;
				}
				if (n && !disk_write(n)) goto fail;
				fpos += n;
				show("ZMODEM receive", fpos);
				if (end == ZCRCW || end == ZCRCQ) { set_pos(fpos); z_hexhdr(ZACK); }
				if (end == ZCRCW || end == ZCRCE) break;
			}
			break;
		case ZEOF:
			if (get_pos() != fpos) break;
			if (open) { cbm_close(LFN); open = 0; }
			z_rinit();
			break;
		case ZFIN:
			set_pos(0); z_hexhdr(ZFIN);
			rx(10); rx(10);                  /* "OO" */
			ui_message("download complete");
			return;
		default:
			z_rinit();
		}
	}
fail:
	for (i = 0; i < 8; i++) ser_put(CAN);
	for (i = 0; i < 8; i++) ser_put(8);
	if (open) cbm_close(LFN);
	ui_message("transfer cancelled");
}

static void z_send(void)
{
	int t;
	unsigned int got, sent_win, win;
	unsigned char tries, i, end;
	aborted = 0;
	if (!open_in()) { ui_message("file not found"); return; }
	net_puts("rz\r");
	for (i = 0; i < 4; i++) hdr[i] = 0;
	z_hexhdr(ZRQINIT);
	for (tries = 0;; ) {
		t = z_gethdr();
		if (t == ZRINIT) break;
		if (aborted || ++tries > 10) goto fail;
		if (t == TIMEOUT) z_hexhdr(ZRQINIT);
	}
	win = hdr[0] | ((unsigned int)hdr[1] << 8);
	/* ZFILE + file information */
	for (;;) {
		for (i = 0; i < 4; i++) hdr[i] = 0;
		hdr[3] = 1;                              /* ZCBIN */
		z_binhdr(ZFILE);
		crc = 0;
		for (i = 0; fname[i]; i++) { unsigned char c = (unsigned char)fname[i]; if (c >= 'A' && c <= 'Z') c += 0x20; zdl_put(c); crc_byte(c); }
		zdl_put(0); crc_byte(0);
		zdl_put('0'); crc_byte('0');             /* size unknown to the C65 DOS */
		zdl_put(0); crc_byte(0);
		net_put(ZDLE); net_put(ZCRCW); crc_byte(ZCRCW);
		zdl_put((unsigned char)(crc >> 8)); zdl_put((unsigned char)crc);
		t = z_gethdr();
		if (t == ZRPOS) break;
		if (t == ZSKIP || aborted) goto fail;
		if (t == ZRINIT) continue;
		if (++tries > 10) goto fail;
	}
	fpos = 0;
	if (get_pos() != 0) goto fail;               /* resuming is not supported */
	set_pos(0); z_binhdr(ZDATA);
	sent_win = 0;
	for (;;) {
		got = cbm_read(LFN, buf, 1024);
		if (got > 1024) got = 0;
		end = (got < 1024) ? ZCRCE : ((win && sent_win + got >= win) ? ZCRCW : ZCRCG);
		crc = 0;
		for (t = 0; t < (int)got; t++) { zdl_put(buf[t]); crc_byte(buf[t]); }
		net_put(ZDLE); net_put(end); crc_byte(end);
		zdl_put((unsigned char)(crc >> 8)); zdl_put((unsigned char)crc);
		fpos += got; sent_win += got;
		show("ZMODEM send", fpos);
		if (end == ZCRCE) break;
		if (end == ZCRCW) {
			t = z_gethdr();
			if (t != ZACK) goto fail;
			sent_win = 0;
			set_pos(fpos); z_binhdr(ZDATA);        /* ZCRCW ended the frame */
		}
		if (cbm_k_getin() == 3) goto fail;
	}
	set_pos(fpos); z_binhdr(ZEOF);
	for (tries = 0; tries < 10; tries++) {
		t = z_gethdr();
		if (t == ZRINIT) break;
		if (t == ZRPOS || aborted) goto fail;
	}
	for (i = 0; i < 4; i++) hdr[i] = 0;
	z_hexhdr(ZFIN);
	t = z_gethdr();
	net_put('O'); net_put('O');
	cbm_close(LFN);
	ui_message("upload complete");
	return;
fail:
	for (i = 0; i < 8; i++) ser_put(CAN);
	cbm_close(LFN);
	ui_message("transfer cancelled");
}

/* ------------------------------------------------------------------ menu */
void xfer_menu(unsigned char download)
{
	unsigned char k;
	scr_status(download ? "download: Z = ZMODEM  X = XMODEM  RUN/STOP = back"
	                    : "upload: Z = ZMODEM  X = XMODEM  RUN/STOP = back");
	k = ui_key();
	if (k != 'z' && k != 'x') { scr_status(""); return; }
	aborted = 0;
	if (download && k == 'z') { fname[0] = 0; zm_receive(); return; }
	fname[0] = 0;                        /* a fresh name each time */
	scr_status(download ? "save as: " : "file to send: ");
	if (!ui_input(download ? 9 : 14, ROWS - 1, fname, 16)) { scr_status(""); return; }
	if (k == 'z') z_send();
	else if (download) x_receive();
	else x_send();
}
