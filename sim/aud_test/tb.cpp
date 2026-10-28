// Audio DMA unit test (rtl/m65_audio.sv): a looping 8-bit sample on channel 0
// with its interrupt armed, and channel 2 in sine mode.
#include "Vm65_audio.h"
#include <cstdio>

double sc_time_stamp() { return 0; }

static Vm65_audio *top;
static unsigned char mem[0x60000];
static long clk = 0;
static bool gnt_next = false;

static void tick() {
	top->clk = 0; top->eval();
	// one bus clock per byte: grant the request, data the clock after
	top->fetch_gnt = top->fetch_req && !gnt_next;
	bool g = top->fetch_gnt;
	top->clk = 1; top->eval();
	top->fetch_q = mem[top->fetch_addr % 0x60000];
	gnt_next = g;
	top->reg_we = 0; top->reg_re = 0;
	clk++;
}
static void wr(int a, int v) { top->reg_addr = a; top->reg_din = v; top->reg_we = 1; tick(); }
static int rd(int a) { top->reg_addr = a; top->reg_re = 1; top->eval(); int v = top->reg_dout; tick(); return v; }

int main() {
	top = new Vm65_audio;
	for (int i = 0; i < 0x1000; i++) mem[0x10000 + i] = i & 0xFF;
	top->reset = 1; for (int i = 0; i < 8; i++) tick(); top->reset = 0; tick();
	int fails = 0;
	wr(0x11, 0x80);                                   // AUDEN
	// channel 0: $10000-$10FFF, 8 bit, looping, fast
	wr(0x21, 0x00); wr(0x22, 0x00); wr(0x23, 0x01);
	wr(0x27, 0x00); wr(0x28, 0x10);                   // top $1000
	wr(0x24, 0x00); wr(0x25, 0x00); wr(0x26, 0x40);   // frequency
	wr(0x29, 0x40);
	wr(0x14, 0x04);                                   // interrupt 4 pages before the top: at $0C00
	wr(0x13, 0x08);                                   // arm channel 0
	wr(0x20, 0xC2);                                   // EN, LOOP, 8 bit
	// channel 2: sine
	wr(0x44, 0x00); wr(0x45, 0x00); wr(0x46, 0x40); wr(0x49, 0x40);
	wr(0x40, 0x90);                                   // EN, sine
	long fired = -1; int at = -1;
	int sine_seen[32] = {0};
	for (long n = 0; n < 2000000 && fired < 0; n++) {
		tick();
		if (!top->irq_n && fired < 0) { fired = clk; at = rd(0x2A) | rd(0x2B) << 8; }
	}
	printf("irq after %ld clk at current address $%04X (expect >= $0C00, a little past)\n", fired, at);
	if (fired < 0 || at < 0x0C00 || at > 0x0C40) fails++;
	int r = rd(0x13);
	printf("$D713 = %02X (expect 80: channel 0 flag, enable cleared)\n", r);
	if (r != 0x80) fails++;
	tick();
	printf("irq_n after reading $D713 = %d (expect 1)\n", top->irq_n);
	if (!top->irq_n) fails++;
	// no second interrupt without re-arming, through a full loop
	bool again = false;
	for (long n = 0; n < 1500000; n++) { tick(); if (!top->irq_n) again = true; }
	printf("interrupt again without re-arming: %d (expect 0)\n", again);
	if (again) fails++;
	// sine: channel 2's current address steps through the table
	int a0 = rd(0x4A);
	for (long n = 0; n < 20000; n++) tick();
	int a1 = rd(0x4A);
	printf("sine channel address moved %d -> %d (expect it to advance)\n", a0, a1);
	if (a0 == a1) fails++;
	printf(fails ? "FAIL (%d)\n" : "all good\n", fails);
	return fails;
}
