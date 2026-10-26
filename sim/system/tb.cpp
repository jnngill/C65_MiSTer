// Whole-system Verilator testbench for c65_core.
//
// usage: tb.exe <rom.bin> <outdir> <frames> [options]
//   -keys <file>     key script: lines of "<frame> <text>" typed starting at that frame
//                    (text escapes: \r = RETURN, {NAME} = raw PS/2 make/break of a hex code)
//   -d81 <file>      mount a disk image (internal drive)
//   -d81b <file>     mount a disk image in the external 1565 drive (drive 1)
//   -dfile <file>    the MEGA65 SD card: a FAT32 image or a single data file (slot 3)
//   -prg <file> <n>  load a .PRG through the OSD program loader at frame n
//   -uartloop        connect the serial port output back to its input
//   -modem <file>    a modem on the serial port (9600 baud): OK to AT commands,
//                    CONNECT on ATDT, then the file as the remote end; what the
//                    C65 sends goes to uart_tx.txt
//   -zsend <name>    after CONNECT, send the -modem file by ZMODEM as <name>
//   -xsend           after CONNECT, send the -modem file by XMODEM when asked
//   -mountat <n>     insert it at frame n (default 2; later avoids auto-booting from it)
//   -shot <n>        write a frame image every n frames (default: last frame only)
//   -trace <n>       dump the last n instruction PCs at exit
//   -stop <hexpc>    stop when an instruction at this PC is executed
//   -after <hexpc>   ...but only once this PC has been executed first
//   -keydelay <n>    extra frames between key events (default 0)
//   -layout <n>      host keyboard layout 0 US, 1 UK, 2 DE, 3 positional (default)
//   -turbo <n>       CPU speed 0 = 3.5 MHz, 1 = 8 MHz, 2 = 16 MHz
//   -xram            fit the 4 MB expansion RAM
//   -mouse <port> <from> <to>   1351 mouse on that control port, moved every frame in [from, to)
//   -ntsc            60 Hz timing
//   -f018a           old DMA list format
#include "Vc65_core.h"
#include "Vc65_core___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <deque>
#include <map>
#include <algorithm>
#include <cctype>

double sc_time_stamp() { return 0; }

static Vc65_core *top;
static std::vector<unsigned char> d81s[3];       // drive 0 (internal), drive 1 (external 1565), 2 = hypervisor data file
static bool d81_dirty[3] = {false, false, false};
static int sd_drv = 0;

// ---- frame capture ---------------------------------------------------
static const int MAXW = 1800, MAXH = 320;     // 1280 pixel modes: 1664 wide
static std::vector<unsigned char> fb(MAXW * MAXH * 3);
static std::vector<unsigned char> idxfb(MAXW * MAXH);   // palette index of each pixel (last frame)
static std::vector<unsigned char> fields[2];     // last complete frame of each interlace field
static int cap_x = 0, cap_y = 0, cap_w = 0, cap_h = 0;
static bool prev_hbl = true, prev_vbl = true;
static long frame_no = 0;
static bool frame_done = false;

static void write_ppm(const std::string &path) {
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) return;
	fprintf(f, "P6\n%d %d\n255\n", cap_w, cap_h * 2);
	for (int y = 0; y < cap_h; y++)
		for (int rep = 0; rep < 2; rep++)
			fwrite(&fb[y * MAXW * 3], 1, cap_w * 3, f);
	fclose(f);
}

static int line_w = 0;
static void video_tick() {
	if (!top->ce_pix) return;
	bool hbl = top->hblank, vbl = top->vblank;
	if (!hbl && !vbl) {
		if (cap_x < MAXW && cap_y < MAXH) {
			unsigned char *p = &fb[(cap_y * MAXW + cap_x) * 3];
			p[0] = top->r * 17; p[1] = top->g * 17; p[2] = top->b * 17;
			idxfb[cap_y * MAXW + cap_x] = top->rootp->c65_core__DOT__vic__DOT__pix_idx;
		}
		cap_x++;
	}
	if (hbl && !prev_hbl) {
		if (!vbl) { if (cap_x > line_w) line_w = cap_x; cap_y++; }
		cap_x = 0;
	}
	if (vbl && !prev_vbl) {
		cap_w = line_w < MAXW ? line_w : MAXW;
		cap_h = cap_y < MAXH ? cap_y : MAXH;
		fields[top->field & 1] = fb;
		cap_y = 0; line_w = 0;
		frame_no++;
		frame_done = true;
	}
	prev_hbl = hbl; prev_vbl = vbl;
}

// ---- keyboard --------------------------------------------------------
struct KeyEv { int code; bool press; };
static std::deque<KeyEv> keyq;
static std::multimap<long, std::string> keyscript;

static void queue_key(int code, bool shift) {
	if (shift) keyq.push_back({0x12, true});
	keyq.push_back({code, true});
	keyq.push_back({code, false});
	if (shift) keyq.push_back({0x12, false});
}

static void queue_char(char c) {
	static const struct { char c; int code; bool shift; } tab[] = {
		{'a',0x1C,0},{'b',0x32,0},{'c',0x21,0},{'d',0x23,0},{'e',0x24,0},{'f',0x2B,0},{'g',0x34,0},{'h',0x33,0},
		{'i',0x43,0},{'j',0x3B,0},{'k',0x42,0},{'l',0x4B,0},{'m',0x3A,0},{'n',0x31,0},{'o',0x44,0},{'p',0x4D,0},
		{'q',0x15,0},{'r',0x2D,0},{'s',0x1B,0},{'t',0x2C,0},{'u',0x3C,0},{'v',0x2A,0},{'w',0x1D,0},{'x',0x22,0},
		{'y',0x35,0},{'z',0x1A,0},{'0',0x45,0},{'1',0x16,0},{'2',0x1E,0},{'3',0x26,0},{'4',0x25,0},{'5',0x2E,0},
		{'6',0x36,0},{'7',0x3D,0},{'8',0x3E,0},{'9',0x46,0},{' ',0x29,0},{'\r',0x5A,0},
		{'!',0x16,1},{'"',0x1E,1},{'#',0x26,1},{'$',0x25,1},{'%',0x2E,1},{'&',0x36,1},{'\'',0x3D,1},{'(',0x3E,1},{')',0x46,1},
		{'+',0x4E,0},{'-',0x55,0},{'@',0x54,0},{'*',0x5B,0},{'=',0x5D,0},{':',0x4C,0},{';',0x52,0},{',',0x41,0},{'.',0x49,0},
		{'/',0x4A,0},{'<',0x41,1},{'>',0x49,1},{'?',0x4A,1},{'[',0x4C,1},{']',0x52,1},{'^',0x17A,0},
	};
	if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
	for (auto &t : tab) if (t.c == c) { queue_key(t.code, t.shift); return; }
}

static void queue_text(const std::string &s) {
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] == '\\' && i + 1 < s.size() && s[i + 1] == 'r') { queue_char('\r'); i++; }
		else if (s[i] == '{') {
			size_t e = s.find('}', i);
			if (e == std::string::npos) break;
			std::string t = s.substr(i + 1, e - i - 1);
			if (t[0] == '+')      keyq.push_back({(int)strtol(t.c_str() + 1, nullptr, 16), true});
			else if (t[0] == '-') keyq.push_back({(int)strtol(t.c_str() + 1, nullptr, 16), false});
			else queue_key((int)strtol(t.c_str(), nullptr, 16), false);
			i = e;
		}
		else queue_char(s[i]);
	}
}

static long key_wait = 0, key_delay = 0;
static void key_frame() {   // called once per frame
	auto r = keyscript.equal_range(frame_no);
	for (auto it = r.first; it != r.second; ++it) queue_text(it->second);
	if (key_wait > 0) { key_wait--; return; }
	if (keyq.empty()) return;
	KeyEv e = keyq.front(); keyq.pop_front();
	int v = top->ps2_key;
	v = ((v ^ 0x400) & 0x400) | (e.press ? 0x200 : 0) | (e.code & 0x1FF);
	top->ps2_key = v;
	key_wait = key_delay;
}

// ---- disk image (hps_io style block device) --------------------------
static int sd_state = 0, sd_cnt = 0;
static unsigned sd_lba_l = 0;
static bool sd_is_wr = false, sd_verbose = false;
static unsigned char sd_wbuf[512];
// ---- scripted modem on the serial port (-modem <file>) -------------------
// Decodes what the C65 sends (8N1 at modem_baud), answers AT commands with
// OK, and on ATDT answers CONNECT and then plays the file as the remote end.
static bool modem_on = false;
static double modem_bit = 0;                  // clocks per bit
static std::vector<unsigned char> modem_file;
static size_t modem_pos = 0;
static std::deque<unsigned char> modem_out;   // bytes queued for the C65
static bool modem_online = false;
static std::string modem_line;
static FILE *modem_log = nullptr;
// receiver (C65 -> modem)
static int mrx_state = 0; static double mrx_t = 0; static int mrx_bits = 0, mrx_n = 0;
// transmitter (modem -> C65)
static int mtx_state = 0; static double mtx_t = 0; static int mtx_byte = 0, mtx_n = 0;
static unsigned long long mclk = 0;
static long modem_hold = 0;                   // clocks to wait before the next file byte

static void modem_send(const char *s) { while (*s) modem_out.push_back((unsigned char)*s++); }

// ---- ZMODEM sender for -zsend (the remote end of a download) ------------
static bool zs_on = false;
static std::string zs_name;
static std::vector<unsigned char> zs_data;
static int zs_state = 0;          // 0 wait ZRINIT, 1 wait ZRPOS, 2 sending / wait ZACK, 3 wait ZRINIT after ZEOF, 4 wait ZFIN, 5 done
static size_t zs_pos = 0;
static std::string zs_hdr;        // hex header being collected from the C65
static int zs_scan = 0;
static unsigned int zs_crc;
static void zs_crcb(unsigned char b) {
	zs_crc ^= (unsigned)b << 8;
	for (int i = 0; i < 8; i++) zs_crc = (zs_crc & 0x8000) ? ((zs_crc << 1) ^ 0x1021) & 0xFFFF : (zs_crc << 1) & 0xFFFF;
}
static void zs_put(unsigned char c) {           // ZDLE-escaped
	switch (c) {
	case 0x18: case 0x10: case 0x11: case 0x13: case 0x90: case 0x91: case 0x93:
		modem_out.push_back(0x18); c ^= 0x40; break;
	}
	modem_out.push_back(c);        // a raw TCP link: no telnet IAC doubling
}
static void zs_hexhdr(int type, unsigned long p) {
	unsigned char h[5] = { (unsigned char)type, (unsigned char)p, (unsigned char)(p >> 8), (unsigned char)(p >> 16), (unsigned char)(p >> 24) };
	char buf[40]; zs_crc = 0;
	for (int i = 0; i < 5; i++) zs_crcb(h[i]);

	snprintf(buf, sizeof buf, "**\x18" "B%02x%02x%02x%02x%02x%04x\r\n\x11", h[0], h[1], h[2], h[3], h[4], zs_crc);
	modem_send(buf);
}
static void zs_binhdr(int type, unsigned long p) {
	unsigned char h[5] = { (unsigned char)type, (unsigned char)p, (unsigned char)(p >> 8), (unsigned char)(p >> 16), (unsigned char)(p >> 24) };
	modem_out.push_back('*'); modem_out.push_back(0x18); modem_out.push_back('A');
	zs_crc = 0;
	for (int i = 0; i < 5; i++) { zs_put(h[i]); zs_crcb(h[i]); }

	zs_put((unsigned char)(zs_crc >> 8)); zs_put((unsigned char)zs_crc);
}
static void zs_sub(const unsigned char *d, size_t n, char end) {
	zs_crc = 0;
	for (size_t i = 0; i < n; i++) { zs_put(d[i]); zs_crcb(d[i]); }
	modem_out.push_back(0x18); modem_out.push_back((unsigned char)end); zs_crcb((unsigned char)end);

	zs_put((unsigned char)(zs_crc >> 8)); zs_put((unsigned char)zs_crc);
}
static void zs_send_block() {                    // one 1K window, ends with ZCRCW (or ZCRCE + ZEOF)
	size_t n = zs_data.size() - zs_pos; if (n > 1024) n = 1024;
	bool last = (zs_pos + n >= zs_data.size());
	zs_sub(&zs_data[zs_pos], n, last ? 'h' : 'k');
	zs_pos += n;
	if (last) { zs_binhdr(11, zs_pos); zs_state = 3; }
}
static void zs_header(int type, unsigned long p) {   // a header from the C65
	fprintf(stderr, "zsend: got header %d pos %lu (state %d)\n", type, p, zs_state);
	if (zs_state == 0 && type == 1) {
		zs_binhdr(4, 0);
		std::string info = zs_name; info.push_back(0); info += std::to_string(zs_data.size()); info.push_back(0);
		zs_sub((const unsigned char *)info.data(), info.size(), 'k');
		zs_state = 1;
	}
	else if (zs_state == 1 && type == 9) { zs_pos = p; zs_binhdr(10, zs_pos); zs_state = 2; zs_send_block(); }
	else if (zs_state == 2 && type == 3) { zs_binhdr(10, zs_pos); zs_send_block(); }   // ZCRCW ended the frame
	else if (zs_state == 2 && type == 9) { zs_pos = p; zs_binhdr(10, zs_pos); zs_send_block(); }
	else if (zs_state == 3 && type == 1) { zs_hexhdr(8, 0); zs_state = 4; }
	else if (zs_state == 4 && type == 8) { modem_send("OO"); zs_state = 5; fprintf(stderr, "zsend: done\n"); }
}
// ---- XMODEM sender for -xsend (128 byte blocks, CRC or checksum) -------
static bool xs_on = false;
static size_t xs_blk = 0;          // next block to send (0-based)
static int xs_state = 0;           // 0 wait C/NAK, 1 wait ACK, 2 EOT sent, 3 done
static bool xs_crc = true;
static void xs_send_block() {
	size_t off = xs_blk * 128;
	if (off >= zs_data.size()) { modem_out.push_back(4); xs_state = 2; return; }
	unsigned char b = (unsigned char)(xs_blk + 1);
	modem_out.push_back(1); modem_out.push_back(b); modem_out.push_back((unsigned char)~b);
	zs_crc = 0; unsigned sum = 0;
	for (int i = 0; i < 128; i++) {
		unsigned char c = (off + i < zs_data.size()) ? zs_data[off + i] : 26;
		modem_out.push_back(c); zs_crcb(c); sum += c;
	}
	if (xs_crc) { modem_out.push_back((unsigned char)(zs_crc >> 8)); modem_out.push_back((unsigned char)zs_crc); }
	else modem_out.push_back((unsigned char)sum);
	xs_state = 1;
}
static void xs_rx(unsigned char c) {
	if (xs_state == 0 && (c == 'C' || c == 21)) { xs_crc = (c == 'C'); fprintf(stderr, "xsend: start (%s)\n", xs_crc ? "CRC" : "checksum"); xs_send_block(); }
	else if (xs_state == 1 && c == 6) { xs_blk++; xs_send_block(); }
	else if (xs_state == 1 && c == 21) { fprintf(stderr, "xsend: NAK block %zu\n", xs_blk + 1); xs_send_block(); }
	else if (xs_state == 2 && c == 6) { xs_state = 3; fprintf(stderr, "xsend: done, %zu blocks\n", xs_blk); }
}

static void zs_rx(unsigned char c) {             // scan the C65's output for hex headers
	if (zs_scan < 4) {
		static const char want[4] = { '*', '*', 0x18, 'B' };
		if (c == want[zs_scan]) zs_scan++; else zs_scan = (c == '*') ? 1 : 0;
		if (zs_scan == 4) zs_hdr.clear();
		return;
	}
	zs_hdr.push_back((char)c);
	if (zs_hdr.size() == 14) {
		unsigned v[7];
		for (int i = 0; i < 7; i++) v[i] = std::stoul(zs_hdr.substr(i * 2, 2), nullptr, 16);
		zs_header(v[0], v[1] | (v[2] << 8) | (v[3] << 16) | ((unsigned long)v[4] << 24));
		zs_scan = 0;
	}
}

static void modem_got(unsigned char c) {
	if (modem_log) fputc(c, modem_log);
	if (modem_online) { if (zs_on) zs_rx(c); if (xs_on) xs_rx(c); return; }
	if (c == 13) {
		std::string l = modem_line; modem_line.clear();
		for (auto &ch : l) ch = toupper(ch);
		if (l.rfind("ATDT", 0) == 0) {
			modem_send("\r\nCONNECT 9600\r\n"); modem_online = true; modem_hold = 3000000;
			if (zs_on) { modem_send("starting a download\r\n"); zs_hexhdr(0, 0); }
		}
		else if (l.rfind("AT", 0) == 0) modem_send("\r\nOK\r\n");
	}
	else if (c >= 32) modem_line += (char)c;
}

static int modem_tick(int txd) {
	mclk++;
	// receive: falling edge starts a frame, sample in the middle of each bit
	if (mrx_state == 0) { if (!txd) { mrx_state = 1; mrx_t = mclk + modem_bit * 1.5; mrx_bits = 0; mrx_n = 0; } }
	else if (mclk >= mrx_t) {
		if (mrx_n < 8) { mrx_bits |= (txd & 1) << mrx_n; mrx_n++; mrx_t += modem_bit; }
		else { modem_got((unsigned char)mrx_bits); mrx_state = 0; }
	}
	// transmit
	if (modem_online && modem_out.empty() && modem_pos < modem_file.size()) {
		if (modem_hold > 0) modem_hold--;
		else modem_out.push_back(modem_file[modem_pos++]);
	}
	static int line = 1;
	if (mtx_state == 0) {
		if (!modem_out.empty()) { mtx_byte = modem_out.front(); modem_out.pop_front(); mtx_state = 1; mtx_n = 0; mtx_t = mclk + modem_bit; line = 0; }
	}
	else if (mclk >= mtx_t) {
		mtx_t += modem_bit;
		if (mtx_n < 8) { line = (mtx_byte >> mtx_n) & 1; mtx_n++; }
		else if (mtx_n == 8) { line = 1; mtx_n++; }
		else { mtx_state = 0; line = 1; }
	}
	return line;
}

static int sd_lat = 200;       // the same for the floppy slots (-fdlat)
static int sd3_lat = 200;      // clocks before the SD card slot answers (-sdlat; the MiSTer takes milliseconds)
static void sd_tick() {
	top->sd_buff_wr = 0;
	switch (sd_state) {
	case 0:
		if (top->sd3_rd || top->sd3_wr) {   // MEGA65 SD card (slot 3)
			sd_drv = 2; sd_is_wr = top->sd3_wr; sd_lba_l = top->sd3_lba; sd_state = 1; sd_cnt = -sd3_lat; top->sd3_ack = 1;
			if (sd_verbose) fprintf(stderr, "sd3 %s lba %u frame %ld\n", sd_is_wr ? "WR" : "RD", sd_lba_l, frame_no);
		}
		else if (top->sd_rd || top->sd_wr) {
			sd_drv = ((top->sd_rd | top->sd_wr) & 2) ? 1 : 0;
			sd_is_wr = (top->sd_wr >> sd_drv) & 1; sd_lba_l = top->sd_lba; sd_state = 1; sd_cnt = -sd_lat; top->sd_ack = 1 << sd_drv;
			if (sd_verbose) fprintf(stderr, "sd%d %s lba %u frame %ld\n", sd_drv, sd_is_wr ? "WR" : "RD", sd_lba_l, frame_no);
		}
		break;
	case 1:
		if (sd_cnt < 0) { sd_cnt++; break; }
		if (sd_cnt & 3) { sd_cnt++; break; }
		{
			int i = sd_cnt >> 2;
			if (i >= 512) { sd_state = 2; break; }
			size_t off = (size_t)sd_lba_l * 256 + i;      // 256 byte blocks, two per F011 sector
			top->sd_buff_addr = i;
			if (!sd_is_wr) {
				top->sd_buff_dout = off < d81s[sd_drv].size() ? d81s[sd_drv][off] : 0;
				top->sd_buff_wr = 1;
			} else if (i > 0) {
				// din for the previous address is valid by now
			}
			sd_cnt++;
		}
		break;
	case 2:
		top->sd_ack = 0; top->sd3_ack = 0; sd_state = 0;
		break;
	}
	if (sd_state == 1 && sd_is_wr && sd_cnt > 0 && (sd_cnt & 3) == 3) {
		int i = sd_cnt >> 2;
		if (i < 512) {
			size_t off = (size_t)sd_lba_l * 256 + i;      // 256 byte blocks, two per F011 sector
			if (off < d81s[sd_drv].size()) { d81s[sd_drv][off] = sd_drv == 2 ? top->sd3_buff_din : top->sd_buff_din; d81_dirty[sd_drv] = true; }
		}
	}
}

// ---- expansion RAM model (4 MB, a few clocks of latency) -------------
static std::vector<unsigned char> xram;
static int xram_cnt = 0;
static void xram_tick() {
	top->xram_ack = 0;
	if (!top->xram_req) { xram_cnt = 0; return; }
	if (++xram_cnt == 4) {
		unsigned a = top->xram_addr & 0xFFFFFF;      // + MEGA65 attic RAM above 8 MB
		if (top->xram_we) xram[a] = top->xram_din;
		top->xram_dout = xram[a];
		top->xram_ack = 1;
	}
	if (xram_cnt > 6) xram_cnt = 6;
}

// ---- text screen dump ------------------------------------------------
static char sc2ascii(unsigned char c) {
	c &= 0x7F;
	if (c == 0) return '@';
	if (c < 27) return 'A' + c - 1;
	if (c >= 32 && c < 64) return (char)c;
	if (c >= 65 && c < 91) return 'a' + c - 65;
	return '.';
}

static void dump_screen(FILE *f) {
	auto *r = top->rootp;
	auto &mem = r->c65_core__DOT__ram__DOT__mem;
	int ctrl_b = r->c65_core__DOT__ctrl_b;
	int vm = r->c65_core__DOT__vic__DOT__vm;
	int bank = (~r->c65_core__DOT__cia2_pa_out) & 3;
	bool h640 = ctrl_b & 0x80;
	int cols = h640 ? 80 : 40;
	int base = (bank << 14) | (h640 ? ((vm & 0xE) << 10) : (vm << 10));
	fprintf(f, "--- screen @%04X %d cols (D031=%02X D030=%02X vic3=%d) frame %ld\n", base, cols, ctrl_b,
		(int)r->c65_core__DOT__ctrl_a, (int)r->c65_core__DOT__vic3_mode, frame_no);
	for (int y = 0; y < 25; y++) {
		std::string line;
		for (int x = 0; x < cols; x++) line += sc2ascii(mem[(base + y * cols + x) & 0x1FFFF]);
		while (!line.empty() && line.back() == ' ') line.pop_back();
		fprintf(f, "%s\n", line.c_str());
	}
	if (!h640) {
		// a program may have switched the video mode while the 80 column text screen is still in use
		fprintf(f, "--- same memory read as the 80 column screen at $0800\n");
		for (int y = 0; y < 25; y++) {
			std::string line;
			for (int x = 0; x < 80; x++) line += sc2ascii(mem[0x800 + y * 80 + x]);
			while (!line.empty() && line.back() == ' ') line.pop_back();
			if (!line.empty()) fprintf(f, "%s\n", line.c_str());
		}
	}
}

int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: tb <rom> <outdir> <frames> [options]\n"); return 2; }
	setvbuf(stdout, nullptr, _IONBF, 0);
	std::string outdir = argv[2];
	long frames = atol(argv[3]);
	int shot = 0, ntrace = 0, stop_pc = -1, after_pc = -1, layout = 3, turbo = 0;
	bool ntsc = false, f018b = true, use_xram = false, stop_brk = false;
	int mouse_port = 0; long mouse_from = 0, mouse_to = 0;
	int m65_ext = 1; bool uart_loop = false; std::string modem_path;
	std::vector<unsigned char> prg; long prg_at = -1; size_t prg_pos = 0; int prg_div = 0; bool prg_busy = false;
	int watch_addr = -1, watch_len = 0; unsigned char watch_old[64] = {0}; bool watch_init = false;
	long mount_frame = 2;
	for (int i = 4; i < argc; i++) {
		std::string a = argv[i];
		if (a == "-keys" && i + 1 < argc) {
			FILE *f = fopen(argv[++i], "r");
			char buf[1024];
			while (f && fgets(buf, sizeof buf, f)) {
				char *sp = strchr(buf, ' ');
				if (!sp) continue;
				std::string t = sp + 1;
				while (!t.empty() && (t.back() == '\n' || t.back() == '\r')) t.pop_back();
				keyscript.insert({atol(buf), t});
			}
			if (f) fclose(f);
		}
		else if ((a == "-d81" || a == "-d81b" || a == "-dfile") && i + 1 < argc) {
			auto &d81 = d81s[a == "-dfile" ? 2 : a == "-d81b" ? 1 : 0];
			FILE *f = fopen(argv[++i], "rb");
			if (f) { d81.resize(256 << 20); size_t n = fread(d81.data(), 1, d81.size(), f); d81.resize(n); fclose(f); }
		}
		else if (a == "-shot" && i + 1 < argc) shot = atoi(argv[++i]);
		else if (a == "-trace" && i + 1 < argc) ntrace = atoi(argv[++i]);
		else if (a == "-stop" && i + 1 < argc) stop_pc = (int)strtol(argv[++i], nullptr, 16);
		else if (a == "-sdlog") sd_verbose = true;
		else if (a == "-layout" && i + 1 < argc) layout = atoi(argv[++i]);
		else if (a == "-keydelay" && i + 1 < argc) key_delay = atol(argv[++i]);
		else if (a == "-ntsc") ntsc = true;
		else if (a == "-xram") use_xram = true;
		else if (a == "-stopbrk") stop_brk = true;
		else if (a == "-watch" && i + 2 < argc) { watch_addr = (int)strtol(argv[++i], nullptr, 16); watch_len = atoi(argv[++i]); }
		else if (a == "-after" && i + 1 < argc) after_pc = (int)strtol(argv[++i], nullptr, 16);
		else if (a == "-mountat" && i + 1 < argc) mount_frame = atol(argv[++i]);
		else if (a == "-strict") m65_ext = 0;
		else if (a == "-sdlat" && i + 1 < argc) sd3_lat = atoi(argv[++i]);
		else if (a == "-fdlat" && i + 1 < argc) sd_lat = atoi(argv[++i]);
		else if (a == "-uartloop") uart_loop = true;
		else if (a == "-modem" && i + 1 < argc) modem_path = argv[++i];
		else if (a == "-zsend" && i + 1 < argc) { zs_on = true; zs_name = argv[++i]; }
		else if (a == "-xsend") xs_on = true;
		else if (a == "-prg" && i + 2 < argc) {
			FILE *f = fopen(argv[++i], "rb");
			if (f) { prg.resize(65536); prg.resize(fread(prg.data(), 1, prg.size(), f)); fclose(f); }
			prg_at = atol(argv[++i]);
		}
		else if (a == "-mouse" && i + 3 < argc) { mouse_port = atoi(argv[++i]); mouse_from = atol(argv[++i]); mouse_to = atol(argv[++i]); }
		else if (a == "-turbo" && i + 1 < argc) turbo = atoi(argv[++i]);
		else if (a == "-f018a") f018b = false;
	}

	std::vector<unsigned char> rom(131072, 0xFF);
	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 3; }
	size_t got = fread(rom.data(), 1, rom.size(), f);
	fclose(f);
	fprintf(stderr, "ROM: %zu bytes\n", got);

	top = new Vc65_core;
	top->ntsc = ntsc; top->dma_f018b = f018b; top->turbo = turbo;
	top->reset_in = 1; top->ld_wr = 0; top->ps2_key = 0; top->rom_backup = 1; top->rrom_ack = 0;
	top->joy1 = 0; top->joy2 = 0; top->kbd_layout = layout;
	top->ps2_mouse = 0; top->mouse_port = mouse_port; top->m65_ext = m65_ext;
	top->prg_dl = 0; top->prg_wr = 0; top->prg_ofs = 0; top->prg_byte = 0;
	top->uart_rxd = 1;
	top->iec_clk_i = 1; top->iec_data_i = 1;     // no IEC device (drives are VHDL and not simulated)
	top->img_mounted = 0; top->img_readonly = 0; top->img_size = 0;
	top->sd_ack = 0; top->sd_buff_wr = 0;
	top->xram_present = use_xram; top->attic_present = 1; top->xram_ack = 0; top->xram_dout = 0;
	// host clock: 2026-10-13 12:34:56 (BCD sec, min, hour, day, month, year, weekday)
	top->rtc[0] = 0x13123456; top->rtc[1] = 0x00022610; top->rtc[2] = 0;
	xram.assign(1 << 24, 0);
	if (!modem_path.empty()) {
		FILE *mf = fopen(modem_path.c_str(), "rb");
		if (!mf) { perror(modem_path.c_str()); return 3; }
		int ch; while ((ch = fgetc(mf)) != EOF) modem_file.push_back((unsigned char)ch);
		fclose(mf);
		modem_on = true;
		// the core's divisor 45 gives 7.09 MHz / 16 / 46 = 9634 baud
		modem_bit = (ntsc ? 32727272.0 : 31527750.0) / (ntsc ? 9724.0 : 9634.0);
		modem_log = fopen((outdir + "/uart_tx.txt").c_str(), "wb");
		if (zs_on || xs_on) { zs_data = modem_file; modem_file.clear(); }
	}

	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	for (int i = 0; i < 4; i++) tick();
	for (unsigned i = 0; i < rom.size(); i++) {
		top->ld_addr = i; top->ld_data = rom[i]; top->ld_wr = 1; tick();
	}
	top->ld_wr = 0;
	for (int i = 0; i < 64; i++) tick();
	top->reset_in = 0;
	top->rtc[2] = 1;      // bit 64 toggles: "time delivered"

	std::deque<std::string> trace;
	std::vector<unsigned> pchist(65536, 0);
	long mount_at = (d81s[0].empty() && d81s[1].empty() && d81s[2].empty()) ? -1 : mount_frame;
	int mount_next = 0;      // the two drives are mounted on consecutive frames
	unsigned long long clks = 0, instrs = 0;

	while (frame_no < frames) {
		tick(); clks++;
		video_tick();
		sd_tick();
		if (uart_loop) top->uart_rxd = top->uart_txd;     // serial loopback plug
		if (modem_on) top->uart_rxd = modem_tick(top->uart_txd);
		// OSD program download: one byte every 8 clocks, like hps_io
		top->prg_wr = 0;
		if (prg_busy && ++prg_div == 8) {
			prg_div = 0;
			if (prg_pos < prg.size()) { top->prg_ofs = (unsigned)prg_pos; top->prg_byte = prg[prg_pos]; top->prg_wr = 1; prg_pos++; }
			else { top->prg_dl = 0; prg_busy = false; printf("prg loaded: %zu bytes, frame %ld\n", prg.size(), frame_no); }
		}
		xram_tick();
		// ROM backup copy (restored after a reset once $20000-$3FFFF was written)
		{
			static int rr = 0;
			top->rrom_ack = 0;
			if (!top->rrom_req) rr = 0;
			else if (++rr == 4) { top->rrom_q = rom[top->rrom_addr]; top->rrom_ack = 1; rr = 0; }
		}
		if (top->dbg_sync && top->rootp->c65_core__DOT__cpu_ce) {
			instrs++;
			if ((int)top->dbg_pc == after_pc) after_pc = -1;
			if (stop_brk && top->dbg_op == 0) { puts("BRK reached"); frames = frame_no; }
			if ((int)top->dbg_pc == stop_pc && after_pc < 0) { puts("stop PC reached"); frames = frame_no; }
			pchist[top->dbg_pc]++;
			if (watch_addr >= 0) {
				for (int w = 0; w < watch_len && w < 64; w++) {
					unsigned char v = top->rootp->c65_core__DOT__ram__DOT__mem[watch_addr + w];
					if (watch_init && v != watch_old[w])
						printf("WATCH %05X %02X->%02X PC=%04X frame %d\n", watch_addr + w, watch_old[w], v, top->dbg_pc, frame_no);
					watch_old[w] = v;
				}
				watch_init = true;
			}
			if (ntrace) {
				char tb_[96];
				snprintf(tb_, sizeof tb_, "%04X A=%02X X=%02X Y=%02X Z=%02X B=%02X SP=%04X P=%02X OP=%02X", top->dbg_pc, top->dbg_a,
					top->dbg_x, top->dbg_y, top->dbg_z, top->dbg_b, top->dbg_sp, top->dbg_p, top->dbg_op);
				trace.push_back(tb_);
				if ((int)trace.size() > ntrace) trace.pop_front();
			}
		}
		top->img_mounted = 0; top->sd3_mounted = 0;
		if (frame_done) {
			frame_done = false;
			key_frame();
			// scripted mouse: +3 right, +2 up per frame, left button held
			if (mouse_port && frame_no >= mouse_from && frame_no < mouse_to)
				top->ps2_mouse = ((top->ps2_mouse ^ 0x1000000) & 0x1000000) | (2 << 16) | (3 << 8) | 0x09;
			else if (frame_no == mouse_to)
				top->ps2_mouse = ((top->ps2_mouse ^ 0x1000000) & 0x1000000) | 0x08;
			// mount drive 0 at mount_at and drive 1 on the next frame (one image per pulse)
			if (mount_at >= 0 && frame_no >= mount_at && mount_next < 3) {
				int d = mount_next++;
				if (!d81s[d].empty()) {
					top->img_size = (unsigned)d81s[d].size(); top->img_readonly = 0;
					if (d == 2) top->sd3_mounted = 1; else top->img_mounted = 1 << d;
				}
			}
			if (frame_no == prg_at && !prg.empty()) { top->prg_dl = 1; prg_busy = true; prg_pos = 0; prg_div = 0; }
			if (shot && frame_no % shot == 0) {
				char name[64]; snprintf(name, sizeof name, "/frame%05ld.ppm", frame_no);
				write_ppm(outdir + name);
			}
		}
	}
	write_ppm(outdir + "/final.ppm");
	{	// palette indices of the last frame, and the VIC state, for comparing with sim/vic_test
		FILE *xf = fopen((outdir + "/final_idx.ppm").c_str(), "wb");
		fprintf(xf, "P6\n%d %d\n255\n", cap_w, cap_h);
		for (int j = 0; j < cap_h; j++)
			for (int i = 0; i < cap_w; i++) { unsigned char g = idxfb[j * MAXW + i]; fputc(g, xf); fputc(g, xf); fputc(g, xf); }
		fclose(xf);
		auto *R = top->rootp;
		printf("VIC: ctrl_c=%02x linestep=%d scrnptr=%05x colptr=%04x charptr=%05x hotreg=%d chrcount=%d/%d bg0=%02x "
		       "mcm=%d ecm=%d bmm=%d den=%d rsel=%d csel=%d xscroll=%d yscroll=%d vm=%x cb=%x\n",
		       R->c65_core__DOT__vic__DOT__ctrl_c, R->c65_core__DOT__vic__DOT__linestep, R->c65_core__DOT__vic__DOT__scrnptr,
		       R->c65_core__DOT__vic__DOT__colptr, R->c65_core__DOT__vic__DOT__charptr, R->c65_core__DOT__vic__DOT__hotreg,
		       R->c65_core__DOT__vic__DOT__dispregs[0], R->c65_core__DOT__vic__DOT__chrcount_hi, R->c65_core__DOT__vic__DOT__col_bg0,
		       R->c65_core__DOT__vic__DOT__mcm, R->c65_core__DOT__vic__DOT__ecm, R->c65_core__DOT__vic__DOT__bmm,
		       R->c65_core__DOT__vic__DOT__den, R->c65_core__DOT__vic__DOT__rsel, R->c65_core__DOT__vic__DOT__csel,
		       R->c65_core__DOT__vic__DOT__xscroll, R->c65_core__DOT__vic__DOT__yscroll, R->c65_core__DOT__vic__DOT__vm,
		       R->c65_core__DOT__vic__DOT__cb);
	}
	{	// chip RAM $00000-$1FFFF, for post-mortem inspection
		FILE *rf = fopen((outdir + "/ram.bin").c_str(), "wb");
		auto &m = top->rootp->c65_core__DOT__ram__DOT__mem;
		for (int i = 0; i < 0x20000; i++) fputc(m[i], rf);
		fclose(rf);
		rf = fopen((outdir + "/ram2.bin").c_str(), "wb");
		auto &m2 = top->rootp->c65_core__DOT__ram2__DOT__mem;
		for (int i = 0; i < 0x20000; i++) fputc(m2[i], rf);
		fclose(rf);
		rf = fopen((outdir + "/rom.bin").c_str(), "wb");
		auto &m4 = top->rootp->c65_core__DOT__rom__DOT__mem;
		for (int i = 0; i < 0x20000; i++) fputc(m4[i], rf);
		fclose(rf);
		rf = fopen((outdir + "/cram2.bin").c_str(), "wb");
		auto &m3 = top->rootp->c65_core__DOT__cram2__DOT__mem;
		for (int i = 0; i < 0x8000; i++) fputc(m3[i], rf);
		fclose(rf);
		rf = fopen((outdir + "/xram.bin").c_str(), "wb");
		fwrite(xram.data(), 1, xram.size(), rf);
		fclose(rf);
	}
	if (!fields[0].empty() && !fields[1].empty()) {
		// both interlace fields woven into one picture
		FILE *wf = fopen((outdir + "/weave.ppm").c_str(), "wb");
		fprintf(wf, "P6\n%d %d\n255\n", cap_w, cap_h * 2);
		for (int y = 0; y < cap_h; y++)
			for (int fl = 0; fl < 2; fl++)
				fwrite(&fields[fl][y * MAXW * 3], 1, cap_w * 3, wf);
		fclose(wf);
	}
	FILE *s = fopen((outdir + "/screen.txt").c_str(), "w");
	dump_screen(s); fclose(s);
	dump_screen(stdout);
	printf("clks %llu instrs %llu frames %ld (%dx%d) PC=%04X\n", clks, instrs, frame_no, cap_w, cap_h, top->dbg_pc);
	if (ntrace) {
		FILE *t = fopen((outdir + "/trace.txt").c_str(), "w");
		for (auto &l : trace) { fputs(l.c_str(), t); fputc(10, t); }
		fclose(t);
		// hottest PCs
		std::vector<std::pair<unsigned, unsigned>> hot;
		for (unsigned i = 0; i < 65536; i++) if (pchist[i]) hot.push_back({pchist[i], i});
		std::sort(hot.rbegin(), hot.rend());
		printf("hot PCs:");
		for (size_t i = 0; i < hot.size() && i < 16; i++) printf(" %04X:%u", hot[i].second, hot[i].first);
		printf("\n");
	}
	for (int d = 0; d < 3; d++) {
		if (!d81_dirty[d]) continue;
		FILE *o = fopen((outdir + (d == 2 ? "/sd_out.img" : d ? "/disk_out_b.d81" : "/disk_out.d81")).c_str(), "wb");
		fwrite(d81s[d].data(), 1, d81s[d].size(), o); fclose(o);
	}
	delete top;
	return 0;
}
