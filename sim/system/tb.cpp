// Whole-system Verilator testbench for c65_core.
//
// usage: tb.exe <rom.bin> <outdir> <frames> [options]
//   -keys <file>     key script: lines of "<frame> <text>" typed starting at that frame
//                    (text escapes: \r = RETURN, {NAME} = raw PS/2 make/break of a hex code)
//   -d81 <file>      mount a disk image (internal drive)
//   -d81b <file>     mount a disk image in the external 1565 drive (drive 1)
//   -prg <file> <n>  load a .PRG through the OSD program loader at frame n
//   -uartloop        connect the serial port output back to its input
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

double sc_time_stamp() { return 0; }

static Vc65_core *top;
static std::vector<unsigned char> d81s[2];       // drive 0 (internal), drive 1 (external 1565)
static bool d81_dirty[2] = {false, false};
static int sd_drv = 0;

// ---- frame capture ---------------------------------------------------
static const int MAXW = 1800, MAXH = 320;     // 1280 pixel modes: 1664 wide
static std::vector<unsigned char> fb(MAXW * MAXH * 3);
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
static void sd_tick() {
	top->sd_buff_wr = 0;
	switch (sd_state) {
	case 0:
		if (top->sd_rd || top->sd_wr) {
			sd_drv = ((top->sd_rd | top->sd_wr) & 2) ? 1 : 0;
			sd_is_wr = (top->sd_wr >> sd_drv) & 1; sd_lba_l = top->sd_lba; sd_state = 1; sd_cnt = -200; top->sd_ack = 1 << sd_drv;
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
		top->sd_ack = 0; sd_state = 0;
		break;
	}
	if (sd_state == 1 && sd_is_wr && sd_cnt > 0 && (sd_cnt & 3) == 3) {
		int i = sd_cnt >> 2;
		if (i < 512) {
			size_t off = (size_t)sd_lba_l * 256 + i;      // 256 byte blocks, two per F011 sector
			if (off < d81s[sd_drv].size()) { d81s[sd_drv][off] = top->sd_buff_din; d81_dirty[sd_drv] = true; }
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
		unsigned a = top->xram_addr & 0x7FFFFF;
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
	int m65_ext = 1; bool uart_loop = false;
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
		else if ((a == "-d81" || a == "-d81b") && i + 1 < argc) {
			auto &d81 = d81s[a == "-d81b" ? 1 : 0];
			FILE *f = fopen(argv[++i], "rb");
			if (f) { d81.resize(819200); size_t n = fread(d81.data(), 1, d81.size(), f); d81.resize(n); fclose(f); }
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
		else if (a == "-uartloop") uart_loop = true;
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
	top->reset = 1; top->ld_wr = 0; top->ps2_key = 0;
	top->joy1 = 0; top->joy2 = 0; top->kbd_layout = layout;
	top->ps2_mouse = 0; top->mouse_port = mouse_port; top->m65_ext = m65_ext;
	top->prg_dl = 0; top->prg_wr = 0; top->prg_ofs = 0; top->prg_byte = 0;
	top->uart_rxd = 1;
	top->iec_clk_i = 1; top->iec_data_i = 1;     // no IEC device (drives are VHDL and not simulated)
	top->img_mounted = 0; top->img_readonly = 0; top->img_size = 0;
	top->sd_ack = 0; top->sd_buff_wr = 0;
	top->xram_present = use_xram; top->xram_ack = 0; top->xram_dout = 0;
	// host clock: 2026-10-13 12:34:56 (BCD sec, min, hour, day, month, year, weekday)
	top->rtc[0] = 0x13123456; top->rtc[1] = 0x00022610; top->rtc[2] = 0;
	xram.assign(1 << 23, 0);

	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	for (int i = 0; i < 4; i++) tick();
	for (unsigned i = 0; i < rom.size(); i++) {
		top->ld_addr = i; top->ld_data = rom[i]; top->ld_wr = 1; tick();
	}
	top->ld_wr = 0;
	for (int i = 0; i < 64; i++) tick();
	top->reset = 0;
	top->rtc[2] = 1;      // bit 64 toggles: "time delivered"

	std::deque<std::string> trace;
	std::vector<unsigned> pchist(65536, 0);
	long mount_at = (d81s[0].empty() && d81s[1].empty()) ? -1 : mount_frame;
	int mount_next = 0;      // the two drives are mounted on consecutive frames
	unsigned long long clks = 0, instrs = 0;

	while (frame_no < frames) {
		tick(); clks++;
		video_tick();
		sd_tick();
		if (uart_loop) top->uart_rxd = top->uart_txd;     // serial loopback plug
		// OSD program download: one byte every 8 clocks, like hps_io
		top->prg_wr = 0;
		if (prg_busy && ++prg_div == 8) {
			prg_div = 0;
			if (prg_pos < prg.size()) { top->prg_ofs = (unsigned)prg_pos; top->prg_byte = prg[prg_pos]; top->prg_wr = 1; prg_pos++; }
			else { top->prg_dl = 0; prg_busy = false; printf("prg loaded: %zu bytes, frame %ld\n", prg.size(), frame_no); }
		}
		xram_tick();
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
		top->img_mounted = 0;
		if (frame_done) {
			frame_done = false;
			key_frame();
			// scripted mouse: +3 right, +2 up per frame, left button held
			if (mouse_port && frame_no >= mouse_from && frame_no < mouse_to)
				top->ps2_mouse = ((top->ps2_mouse ^ 0x1000000) & 0x1000000) | (2 << 16) | (3 << 8) | 0x09;
			else if (frame_no == mouse_to)
				top->ps2_mouse = ((top->ps2_mouse ^ 0x1000000) & 0x1000000) | 0x08;
			// mount drive 0 at mount_at and drive 1 on the next frame (one image per pulse)
			if (mount_at >= 0 && frame_no >= mount_at && mount_next < 2) {
				int d = mount_next++;
				if (!d81s[d].empty()) { top->img_size = (unsigned)d81s[d].size(); top->img_readonly = 0; top->img_mounted = 1 << d; }
			}
			if (frame_no == prg_at && !prg.empty()) { top->prg_dl = 1; prg_busy = true; prg_pos = 0; prg_div = 0; }
			if (shot && frame_no % shot == 0) {
				char name[64]; snprintf(name, sizeof name, "/frame%05ld.ppm", frame_no);
				write_ppm(outdir + name);
			}
		}
	}
	write_ppm(outdir + "/final.ppm");
	{	// chip RAM $00000-$1FFFF, for post-mortem inspection
		FILE *rf = fopen((outdir + "/ram.bin").c_str(), "wb");
		auto &m = top->rootp->c65_core__DOT__ram__DOT__mem;
		for (int i = 0; i < 0x20000; i++) fputc(m[i], rf);
		fclose(rf);
		rf = fopen((outdir + "/ram2.bin").c_str(), "wb");
		auto &m2 = top->rootp->c65_core__DOT__ram2__DOT__mem;
		for (int i = 0; i < 0x20000; i++) fputc(m2[i], rf);
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
	for (int d = 0; d < 2; d++) {
		if (!d81_dirty[d]) continue;
		FILE *o = fopen((outdir + (d ? "/disk_out_b.d81" : "/disk_out.d81")).c_str(), "wb");
		fwrite(d81s[d].data(), 1, d81s[d].size(), o); fclose(o);
	}
	delete top;
	return 0;
}
