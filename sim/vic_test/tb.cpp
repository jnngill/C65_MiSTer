// Video-chip-only test: rtl/vic3.sv fed from the system sim's memory dumps.
//
// usage: victest.exe <dumpdir> <regs.txt> <frames> <out.ppm> [lb.bin]
//   regs.txt: lines "<hex reg> <hex value>" written in order (reg $00-$7F;
//   2F knock values included), after which the VIC runs <frames> frames.
//   out.ppm gets the palette index of every pixel of the last frame (grey),
//   lb.bin the line buffer contents at the end.
#include "Vvic3.h"
#include "Vvic3___024root.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>

double sc_time_stamp() { return 0; }

static Vvic3 *top;
static std::vector<unsigned char> mem(0x80000, 0);   // video address space
static std::vector<unsigned char> crom(0x20000, 0);  // ROM image (char ROM shadow)

static void load(const std::string &p, size_t at, size_t n, std::vector<unsigned char> &m) {
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) { fprintf(stderr, "missing %s\n", p.c_str()); return; }
	fread(&m[at], 1, n, f); fclose(f);
}

static unsigned long long clk = 0;
static void tick() {
	// registered memory: the address seen before the edge is answered after it
	unsigned a = top->vaddr & 0x7FFFF;
	top->clk = 0; top->eval();
	top->ce_pix = (clk & 1);
	top->clk = 1; top->eval();
	top->vram_q = mem[a];
	top->vrom_q = crom[a & 0x1FFFF];
	top->reg_we = 0; top->reg_re = 0; top->pal_we = 0;
	clk++;
}

int main(int argc, char **argv) {
	if (argc < 5) { fprintf(stderr, "usage: victest dumpdir regs frames out.ppm [lb.bin]\n"); return 2; }
	std::string d = argv[1];
	load(d + "/ram.bin", 0x00000, 0x20000, mem);
	load(d + "/rom.bin", 0x20000, 0x20000, mem);
	load(d + "/ram2.bin", 0x40000, 0x20000, mem);
	// colour RAM beyond the first 2K is seen at $60000
	{
		std::vector<unsigned char> c(0x8000, 0);
		load(d + "/cram2.bin", 0, 0x8000, c);
		for (int i = 0; i < 0x7800; i++) mem[0x60000 + i] = c[i];
	}
	for (int i = 0; i < 0x20000; i++) crom[i] = mem[0x20000 + i];

	top = new Vvic3;
	top->reset = 1; top->ntsc = 0; top->vic3_mode = 1; top->vic4_mode = 1;
	top->vic_bank = 0; top->pal_addr = 0;
	for (int i = 0; i < 8; i++) tick();
	top->reset = 0;
	tick();

	FILE *rf = fopen(argv[2], "r");
	unsigned r, v;
	while (rf && fscanf(rf, "%x %x", &r, &v) == 2) {
		top->reg_addr = r; top->reg_din = v; top->reg_we = 1;
		top->clk = 0; top->eval(); top->clk = 1; top->eval(); clk++;
		top->reg_we = 0;
		for (int i = 0; i < 4; i++) tick();
	}
	if (rf) fclose(rf);

	int frames = atoi(argv[3]);
	const int W = 1100, H = 320;
	std::vector<unsigned char> fb(W * H, 0);
	int x = 0, y = 0, fr = 0;
	bool phb = false, pvb = false;
	while (fr < frames) {
		tick();
		if (!top->pix_ce) continue;
		bool hb = top->hblank, vb = top->vblank;
		if (!hb && !vb && x < W && y < H) fb[y * W + x] = top->rootp->vic3__DOT__pix_idx;
		if (!hb && !vb) x++;
		if (hb && !phb) { if (!vb) y++; x = 0; }
		if (vb && !pvb) { fr++; if (fr < frames) { y = 0; std::fill(fb.begin(), fb.end(), 0); } }
		phb = hb; pvb = vb;
	}
	FILE *o = fopen(argv[4], "wb");
	fprintf(o, "P6\n%d %d\n255\n", 832, 290);
	for (int j = 0; j < 290; j++)
		for (int i = 0; i < 832; i++) { unsigned char g = fb[j * W + i]; fputc(g, o); fputc(g, o); fputc(g, o); }
	fclose(o);
	if (argc > 5) {
		FILE *l = fopen(argv[5], "wb");
		auto &m = top->rootp->vic3__DOT__linebuf__DOT__mem;
		for (int i = 0; i < 2048; i++) { unsigned short e = m[i]; fputc(e & 255, l); fputc(e >> 8, l); }
		fclose(l);
	}
	printf("done, %llu clk\n", clk);
	return 0;
}
