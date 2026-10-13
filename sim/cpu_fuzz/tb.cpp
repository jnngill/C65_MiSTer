// CPU fuzz harness: runs cpu4510 on a 1MB memory image and writes a
// per-instruction register trace (compared against sim/ref by run.sh).
#include "Vcpu4510.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
double sc_time_stamp() { return 0; }
int main(int argc, char **argv) {
	if (argc < 4) return 2;
	std::vector<unsigned char> mem(1 << 20);
	FILE *f = fopen(argv[1], "rb");
	if (!f || fread(mem.data(), 1, mem.size(), f) != mem.size()) return 3;
	fclose(f);
	FILE *o = fopen(argv[2], "wb");
	long n = atol(argv[3]), count = 0;
	unsigned lcg = 12345;
	Vcpu4510 t;
	t.irq_n = 1; t.nmi_n = 1; t.ce = 1;
	t.gs = (argc > 4);
	t.reset = 1;
	for (int i = 0; i < 4; i++) { t.clk = 0; t.eval(); t.clk = 1; t.eval(); }
	t.reset = 0;
	while (count < n) {
		t.clk = 0; t.eval();
		unsigned a = t.far_sel ? (t.far_addr & 0xFFFFF) : t.paddr;
		t.din = mem[a]; t.eval();
		if (t.sync) {
			// every 64th instruction is replaced by a JMP to a random address so
			// the run cannot get stuck in a small loop (ref_trace.py does the same)
			if ((count & 63) == 63 && (t.dbg_pc & 0x1FFF) < 0x1FFD) {
				lcg = (lcg * 1103515245u + 12345u) & 0x7FFFFFFFu;
				unsigned tgt = (lcg >> 8) & 0xFFFF;
				mem[t.paddr] = 0x4C; mem[t.paddr + 1] = tgt & 255; mem[t.paddr + 2] = tgt >> 8;
				t.din = mem[a]; t.eval();
			}
			fprintf(o, "%04X %02X %02X %02X %02X %02X %04X %02X\n", t.dbg_pc, t.dbg_a, t.dbg_x,
				t.dbg_y, t.dbg_z, t.dbg_b, t.dbg_sp, t.dbg_p);
			count++;
		}
		if (t.we) mem[a] = t.dout;
		t.clk = 1; t.eval();
	}
	fclose(o);
	return 0;
}
