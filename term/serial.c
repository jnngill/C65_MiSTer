/* The connection: the MiSTer's emulated modem on the serial port, with a
** telnet layer once connected (midilink's own negotiation is switched off
** with ATTEL0 so that binary transfers pass untouched).
*/
#include "ascii.h"
#include "term.h"

#define IAC  255
#define DONT 254
#define DO   253
#define WONT 252
#define WILL 251
#define SB   250
#define SE   240
#define OPT_BINARY 0
#define OPT_ECHO   1
#define OPT_SGA    3
#define OPT_TTYPE  24
#define OPT_NAWS   31

unsigned char telnet;               /* 0 raw, 1 telnet, 2 decide from the first bytes */
static unsigned char auto_count;
static unsigned char tstate, tcmd, sbopt, sbpos, after_cr;
static unsigned char bin_rx;        /* the server sends in binary mode: CR NUL is not special */
static const char *const ttype_name[3] = { "ANSI", "VT100", "PETSCII" };

static void raw3(unsigned char a, unsigned char b, unsigned char c)
{
	ser_put(a); ser_put(b); ser_put(c);
}

static void send_naws(void)
{
	raw3(IAC, SB, OPT_NAWS);
	ser_put(0); ser_put(cols); ser_put(0); ser_put(ROWS);
	ser_put(IAC); ser_put(SE);
}

static void send_ttype(void)
{
	const char *s = ttype_name[emu];
	raw3(IAC, SB, OPT_TTYPE);
	ser_put(0);
	while (*s) ser_put((unsigned char)*s++);
	ser_put(IAC); ser_put(SE);
}

static void option(unsigned char cmd, unsigned char opt)
{
	if (cmd == DO) {
		if (opt == OPT_BINARY || opt == OPT_SGA || opt == OPT_TTYPE || opt == OPT_NAWS) {
			raw3(IAC, WILL, opt);
			if (opt == OPT_NAWS) send_naws();
		}
		else raw3(IAC, WONT, opt);
	}
	else if (cmd == WILL) {
		if (opt == OPT_BINARY || opt == OPT_ECHO || opt == OPT_SGA) raw3(IAC, DO, opt);
		else raw3(IAC, DONT, opt);
		if (opt == OPT_BINARY) bin_rx = 1;
	}
	else if (cmd == WONT && opt == OPT_BINARY) bin_rx = 0;
}

/* next data byte from the connection, or -1 */
int net_get(void)
{
	int r;
	unsigned char c;
	for (;;) {
		r = ser_get();
		if (r < 0) return -1;
		c = (unsigned char)r;
		if (telnet == 2) {
			/* telnet servers negotiate straight away; a raw TCP BBS (often a
			** real C64 behind a WiFi modem) never sends IAC, and there IAC
			** handling would eat $FF bytes of binary files */
			if (c == IAC) telnet = 1;
			else if (++auto_count >= 32) telnet = 0;
			else return c;
		}
		if (!telnet) return c;
		switch (tstate) {
		case 0:
			if (c == IAC) { tstate = 1; continue; }
			if (after_cr && c == 0 && !bin_rx) { after_cr = 0; continue; }
			after_cr = (c == 13);
			return c;
		case 1:                         /* after IAC */
			if (c == IAC) { tstate = 0; return IAC; }
			if (c == SB) { tstate = 3; continue; }
			if (c >= WILL && c <= DONT) { tcmd = c; tstate = 2; continue; }
			tstate = 0;
			continue;
		case 2:                         /* IAC WILL/WONT/DO/DONT opt */
			option(tcmd, c);
			tstate = 0;
			continue;
		case 3:                         /* IAC SB opt */
			sbopt = c; sbpos = 0; tstate = 4;
			continue;
		case 4:                         /* sub-negotiation data, until IAC SE */
			if (c == IAC) { tstate = 5; continue; }
			if (sbpos++ == 0 && sbopt == OPT_TTYPE && c == 1) send_ttype();
			continue;
		case 5:
			tstate = (c == SE) ? 0 : 4;
			continue;
		}
	}
}

void net_put(unsigned char b)
{
	if (telnet == 1 && b == IAC) ser_put(IAC);
	ser_put(b);
}

void net_puts(const char *s)
{
	while (*s) ser_put((unsigned char)*s++);
}

void net_flush_in(void)
{
	while (ser_get() >= 0) ;
	tstate = 0;
	if (!telnet) bin_rx = 0;
	auto_count = 0;
}

/* tenths of a second from the CIA time-of-day clock (wraps every hour) */
unsigned int ticks(void)
{
	unsigned char m, s, t;
	(void)*(volatile unsigned char *)0xDC0B;          /* latch */
	m = *(volatile unsigned char *)0xDC0A;
	s = *(volatile unsigned char *)0xDC09;
	t = *(volatile unsigned char *)0xDC08;            /* unlatch */
	m = (m >> 4) * 10 + (m & 15);
	s = (s >> 4) * 10 + (s & 15);
	return ((unsigned int)m * 60 + s) * 10 + (t & 15);
}
