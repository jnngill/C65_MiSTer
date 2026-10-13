// Whole-system Verilator testbench for c65_core.
//
// usage: tb.exe <rom.bin> <outdir> <frames> [options]
//   -keys <file>     key script: lines of "<frame> <text>" typed starting at that frame
//                    (text escapes: \r = RETURN, {NAME} = raw PS/2 make/break of a hex code)
//   -d81 <file>      mount a disk image
//   -shot <n>        write a frame image every n frames (default: last frame only)
//   -trace <n>       dump the last n instruction PCs at exit
//   -stop <hexpc>    stop when an instruction at this PC is executed
//   -keydelay <n>    extra frames between key events (default 0)
//   -layout <n>      host keyboard layout 0 US, 1 UK, 2 DE, 3 positional (default)
//   -turbo <n>       CPU speed 0 = 3.5 MHz, 1 = 8 MHz, 2 = 16 MHz
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
static std::vector<unsigned char> d81;
static bool d81_dirty = false;

// ---- frame capture ---------------------------------------------------
static const int MAXW = 1100, MAXH = 320;
static std::vector<unsigned char> fb(MAXW * MAXH * 3);
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
			sd_is_wr = top->sd_wr; sd_lba_l = top->sd_lba; sd_state = 1; sd_cnt = -200; top->sd_ack = 1;
			if (sd_verbose) fprintf(stderr, "sd %s lba %u frame %ld\n", sd_is_wr ? "WR" : "RD", sd_lba_l, frame_no);
		}
		break;
	case 1:
		if (sd_cnt < 0) { sd_cnt++; break; }
		if (sd_cnt & 3) { sd_cnt++; break; }
		{
			int i = sd_cnt >> 2;
			if (i >= 512) { sd_state = 2; break; }
			size_t off = (size_t)sd_lba_l * 512 + i;
			top->sd_buff_addr = i;
			if (!sd_is_wr) {
				top->sd_buff_dout = off < d81.size() ? d81[off] : 0;
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
			size_t off = (size_t)sd_lba_l * 512 + i;
			if (off < d81.size()) { d81[off] = top->sd_buff_din; d81_dirty = true; }
		}
	}
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
}

int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: tb <rom> <outdir> <frames> [options]\n"); return 2; }
	setvbuf(stdout, nullptr, _IONBF, 0);
	std::string outdir = argv[2];
	long frames = atol(argv[3]);
	int shot = 0, ntrace = 0, stop_pc = -1, layout = 3, turbo = 0;
	bool ntsc = false, f018b = true;
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
		else if (a == "-d81" && i + 1 < argc) {
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
	top->img_mounted = 0; top->img_readonly = 0; top->img_size = 0;
	top->sd_ack = 0; top->sd_buff_wr = 0;

	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	for (int i = 0; i < 4; i++) tick();
	for (unsigned i = 0; i < rom.size(); i++) {
		top->ld_addr = i; top->ld_data = rom[i]; top->ld_wr = 1; tick();
	}
	top->ld_wr = 0;
	for (int i = 0; i < 64; i++) tick();
	top->reset = 0;

	std::deque<std::string> trace;
	std::vector<unsigned> pchist(65536, 0);
	long mount_at = d81.empty() ? -1 : 2;
	unsigned long long clks = 0, instrs = 0;

	while (frame_no < frames) {
		tick(); clks++;
		video_tick();
		sd_tick();
		if (top->dbg_sync && top->rootp->c65_core__DOT__cpu_ce) {
			instrs++;
			if ((int)top->dbg_pc == stop_pc) { puts("stop PC reached"); frames = frame_no; }
			pchist[top->dbg_pc]++;
			if (ntrace) {
				char tb_[96];
				snprintf(tb_, sizeof tb_, "%04X A=%02X X=%02X Y=%02X Z=%02X B=%02X SP=%04X P=%02X", top->dbg_pc, top->dbg_a,
					top->dbg_x, top->dbg_y, top->dbg_z, top->dbg_b, top->dbg_sp, top->dbg_p);
				trace.push_back(tb_);
				if ((int)trace.size() > ntrace) trace.pop_front();
			}
		}
		top->img_mounted = 0;
		if (frame_done) {
			frame_done = false;
			key_frame();
			if (frame_no == mount_at) {
				top->img_size = (unsigned)d81.size(); top->img_readonly = 0; top->img_mounted = 1;
			}
			if (shot && frame_no % shot == 0) {
				char name[64]; snprintf(name, sizeof name, "/frame%05ld.ppm", frame_no);
				write_ppm(outdir + name);
			}
		}
	}
	write_ppm(outdir + "/final.ppm");
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
	if (d81_dirty) {
		FILE *o = fopen((outdir + "/disk_out.d81").c_str(), "wb");
		fwrite(d81.data(), 1, d81.size(), o); fclose(o);
	}
	delete top;
	return 0;
}
