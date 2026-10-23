// Check the plain line doubler in sys/scandoubler.v: feed lines whose pixels
// encode (line, column) and check every output line repeats one input line.
// Build: see run.sh.  -v prints the timing of a few output lines.
#include "Vscandoubler.h"
#include "Vscandoubler___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <map>

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	bool verbose = argc > 1 && !strcmp(argv[1], "-v");
	auto *t = new Vscandoubler;
	const int W = 200, HB = 60, H = 40, VB = 6, DIV = 4;     // pixels, blank, lines; clk per pixel
	const long LINE = (W + HB) * DIV, FRAME = LINE * (H + VB);
	int x = 0, y = 0, sub = 0;
	std::vector<int> cur; std::vector<std::vector<int>> outl;
	bool prev_hb = true;
	for (long clk = 0; clk < 3 * FRAME; clk++) {
		t->ce_pix = (sub == 0);
		bool hb = x >= W, vb = y >= H;
		t->hb_in = hb; t->vb_in = vb;
		t->hs_in = (x >= W + 10 && x < W + 30);
		t->vs_in = (y == H + 2);
		int v = ((y & 15) << 8) | (x & 0xFF);              // 12 bits: line in r, column in g/b
		t->r_in = (v >> 8) & 15; t->g_in = (v >> 4) & 15; t->b_in = v & 15;
		t->clk_vid = 0; t->eval(); t->clk_vid = 1; t->eval();
		bool show = verbose && clk > 2 * FRAME + 3 * LINE && clk < 2 * FRAME + 6 * LINE;
		if (t->ce_pix_out) {
			if (!t->hb_out && prev_hb && show)
				printf("out start: input x=%3d y=%2d  wl=%d rl=%d\n", x, y, t->rootp->scandoubler__DOT__lb_wl, t->rootp->scandoubler__DOT__lb_rl);
			if (!t->hb_out && !t->vb_out) cur.push_back((t->r_out << 8) | (t->g_out << 4) | t->b_out);
			if (t->hb_out && !prev_hb) {
				if (show) printf("out end:   input x=%3d y=%2d  wl=%d rl=%d  first %03x last %03x\n", x, y,
					t->rootp->scandoubler__DOT__lb_wl, t->rootp->scandoubler__DOT__lb_rl, cur.empty() ? 0 : cur[0], cur.empty() ? 0 : cur.back());
				if (!cur.empty()) outl.push_back(cur);
				cur.clear();
			}
			prev_hb = t->hb_out;
		}
		if (++sub == DIV) { sub = 0; if (++x == W + HB) { x = 0; if (++y == H + VB) y = 0; } }
	}
	if (verbose) {
		auto &lb = t->rootp->scandoubler__DOT__lbuf;
		for (int bsel = 0; bsel < 2; bsel++) {
			printf("buffer %d:", bsel);
			for (int i : {0, 1, 2, 3, 4, 60, 61, 62, 63, 64, 196, 197, 198, 199, 200, 201, 259, 260})
				printf(" [%d]=%03x", i, (int)lb[bsel * 2048 + i]);
			printf("\n");
		}
	}
	// the last frame's worth of output lines
	int good = 0, bad = 0; std::map<int,int> lens;
	for (size_t i = outl.size() > 2 * H ? outl.size() - 2 * H : 0; i < outl.size(); i++) {
		auto &l = outl[i]; lens[(int)l.size()]++;
		bool ok = l.size() >= (size_t)W - 4 && (l[0] & 0xFF) <= 1;
		for (size_t k = 1; ok && k < l.size(); k++)
			if ((l[k] & 0xFF) != ((l[k - 1] + 1) & 0xFF) || (l[k] >> 8) != (l[0] >> 8)) ok = false;
		ok ? good++ : bad++;
	}
	printf("output lines checked: %d ok, %d bad; lengths:", good, bad);
	for (auto &p : lens) printf(" %d x%d", p.first, p.second);
	printf("\n");
	delete t;
	return bad ? 1 : 0;
}
