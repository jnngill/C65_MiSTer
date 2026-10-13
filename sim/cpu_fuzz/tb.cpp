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
	Vcpu4510 t;
	t.irq_n = 1; t.nmi_n = 1; t.ce = 1;
	t.reset = 1;
	for (int i = 0; i < 4; i++) { t.clk = 0; t.eval(); t.clk = 1; t.eval(); }
	t.reset = 0;
	while (count < n) {
		t.clk = 0; t.eval();
		t.din = mem[t.paddr]; t.eval();
		if (t.sync) {
			fprintf(o, "%04X %02X %02X %02X %02X %02X %04X %02X\n", t.dbg_pc, t.dbg_a, t.dbg_x,
				t.dbg_y, t.dbg_z, t.dbg_b, t.dbg_sp, t.dbg_p);
			count++;
		}
		if (t.we) mem[t.paddr] = t.dout;
		t.clk = 1; t.eval();
	}
	fclose(o);
	return 0;
}
