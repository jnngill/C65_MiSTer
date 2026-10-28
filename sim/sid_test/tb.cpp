// SID-only test: drives rtl/sid/sid_top.sv (built with QUAD = 0 or 1) with a
// fixed register script and prints one line of outputs every 64 SID cycles.
//   tb.exe <out.txt>
#include "Vsid_top.h"
#include <cstdio>

double sc_time_stamp() { return 0; }

static Vsid_top *top;
static long clk = 0;

static void tick() {
	top->clk = 0; top->eval();
	top->ce_1m = (clk % 32) == 31;
	top->clk = 1; top->eval();
	top->cs = 0; top->we = 0;
	clk++;
}

// write a register of chip c, outside the SID's busy states
static void wr(int c, int a, int v) {
	while ((clk % 32) != 0) tick();
	top->cs = 1 << c; top->we = 1; top->addr = a; top->data_in = v;
	tick();
}

static int rd(int c, int a) {
	while ((clk % 32) != 0) tick();
	top->cs = 1 << c; top->we = 0; top->addr = a;
	tick();
	top->cs = 1 << c; top->addr = a;
	top->eval();
	return top->data_out;
}

int main(int argc, char **argv) {
	top = new Vsid_top;
	FILE *o = fopen(argv[1], "w");
	top->reset = 1; for (int i = 0; i < 64; i++) tick(); top->reset = 0;
	top->filter_en = 0xF; top->mode = 0xF; top->cfg = 0;
	top->pot_x_l = 0x11; top->pot_y_l = 0x22; top->pot_x_r = 0x33; top->pot_y_r = 0x44;
	int chips = argc > 2 ? 4 : 2;
	// "swap": chip c's settings go to chip (c + 2) % 4, so a two-chip build plays chips 2 / 3
	int sw = (argc > 2 && argv[2][0] == 's') ? 2 : 0;
	if (sw) chips = 2;
	// per chip: voice 1 with its own waveform and pitch, low-pass filtered on
	// chips 0 and 2, full volume
	const int wave[4] = {0x21, 0x41, 0x11, 0x81};
	for (int c = 0; c < 4; c++) {   // all four in both builds, so the timing matches
		int c0 = c; c = (c + sw) % 4;
		wr(c, 0x00, 0x00); wr(c, 0x01, 0x08 + 6 * c0);   // frequency
		wr(c, 0x02, 0x00); wr(c, 0x03, 0x08);           // pulse width 50%
		wr(c, 0x05, 0x09); wr(c, 0x06, 0xF0);           // attack 0, decay 9, sustain F
		wr(c, 0x15, 0x00); wr(c, 0x16, 0x30);           // cutoff
		wr(c, 0x17, (c0 % 2) ? 0x00 : 0xF1);             // voice 1 through the filter
		wr(c, 0x18, (c0 % 2) ? 0x0F : 0x1F);             // LP, volume 15
		wr(c, 0x04, wave[c0]);                          // gate on
		c = c0;
	}
	for (int n = 0; n < 400; n++) {
		for (int i = 0; i < 64 * 32; i++) tick();
		fprintf(o, "%d %d", (int)((top->audio_l << 14) >> 14), (int)((top->audio_r << 14) >> 14));
#ifndef OLD
		if (chips == 4) fprintf(o, " %d %d", (int)((top->audio_c2 << 14) >> 14), (int)((top->audio_c3 << 14) >> 14));
#endif
		fprintf(o, "\n");
		if (n == 200) for (int c = 0; c < 4; c++) wr((c + sw) % 4, 0x04, wave[c] & 0xFE);   // gate off
	}
	// envelope / oscillator 3 and POT read-back of each chip
	for (int c = 0; c < chips; c++) fprintf(o, "chip %d pot %02x %02x\n", c, rd(c, 0x19), rd(c, 0x1A));
	fclose(o);
	return 0;
}
