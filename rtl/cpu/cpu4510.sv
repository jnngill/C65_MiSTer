// CSG 4510 CPU core (65CE02 + MAP) for the C65 MiSTer core.
//
// With gs=1 the 45GS02 (MEGA65) prefixes used by MEGA65 ROMs are decoded:
//   NEG NEG <op>      32-bit operation on Q = {Z,Y,X,A}
//   EOM <op (nn),Z>   32-bit pointer at nn: [nn],Z far addressing (28 bit)
//   NEG NEG EOM <op>  both
//
// Bus protocol: addr/paddr/dout/we are combinational from the CPU state and
// stay stable for the whole CPU cycle; the cycle ends on a clk edge with ce=1,
// at which point din must hold the read data.  Instruction-accurate, not
// cycle-accurate.  Verified against sim/ref/cpu4510.py (sim/cpu_fuzz).

module cpu4510 (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,
	input  logic        irq_n,
	input  logic        nmi_n,
	input  logic        gs,       // enable 45GS02 prefix instructions

	output logic        far_sel,  // access uses far_addr (flat 28 bit) instead of addr/paddr
	output logic [27:0] far_addr,
	output logic [15:0] addr,     // CPU (virtual) address
	output logic [19:0] paddr,    // address after MAP translation
	output logic        mapped,   // paddr comes from a MAPped block
	output logic  [7:0] dout,
	output logic        we,
	input  logic  [7:0] din,
	output logic        sync,     // opcode fetch cycle

	// MEGA65 hypervisor trap results: load A / X / Y and the carry flag.  Only
	// pulsed while the bus is held between instructions (state S_FETCH).
	input  logic        hyp_load,
	input  logic  [7:0] hyp_a, hyp_x, hyp_y,
	input  logic        hyp_c,
	// MEGA65 inline DMA ($D707) done: continue after the DMA list
	input  logic        pc_load,
	input  logic [15:0] pc_val,

	output logic [15:0] dbg_pc,
	output logic  [7:0] dbg_a, dbg_x, dbg_y, dbg_z, dbg_b, dbg_p,
	output logic [15:0] dbg_sp
);

`include "cpu4510_tables.svh"

typedef enum logic [4:0] {
	S_VECLO, S_VECHI, S_FETCH, S_OP1, S_OP2, S_PTRLO, S_PTRHI, S_PTR2, S_PTR3,
	S_READ, S_READ2, S_WRITE, S_WRITE2, S_BBREL,
	S_PUSH_PCH, S_PUSH_PCL, S_PUSH_P, S_PUSH_REG, S_PUSH_WLO, S_PUSH_WHI,
	S_PULL_REG, S_PULL_P, S_PULL_PCL, S_PULL_PCH
} state_t;

localparam logic [1:0] INT_NONE = 2'd0, INT_BRK = 2'd1, INT_IRQ = 2'd2, INT_NMI = 2'd3;

state_t      state;
logic  [7:0] A, X, Y, Z, B;
logic [15:0] SP, PC;
logic        fN, fV, fE, fD, fI, fZ, fC;
logic  [7:0] IR, lo, data, datah;
logic [15:0] ea, ptr, vec;
logic  [1:0] intr;
logic        nmi_d, nmi_pend;

// 45GS02 prefix state
logic  [1:0] neg_cnt;     // consecutive NEGs seen (2 = next instruction works on Q)
logic        far_pfx;     // EOM seen: next (nn),Z instruction uses a 32-bit pointer
logic        q_op, far_op;   // latched for the instruction being executed
logic        ea_far;
logic [27:0] fea;
logic  [7:0] fp1, fp2;
logic [31:0] val32;
logic  [1:0] qi;

// RTS #nn: the immediate is latched into lo at S_OP1, but lo is reused for
// PCL during the pulls, so keep a private copy.
logic  [7:0] IR_arg;
always_ff @(posedge clk) if (ce && state == S_OP1) IR_arg <= din;

logic [11:0] map_lo, map_hi;
logic  [7:0] map_en;
logic        map_inhibit;

// ---------------------------------------------------------------- decode
ins_t  ins,  f_ins;
mode_t mode, f_mode;
assign ins    = ins_lut(IR);
assign mode   = mode_lut(IR);
assign f_ins  = ins_lut(din);
assign f_mode = mode_lut(din);

wire is_store = (ins == I_STA) || (ins == I_STX) || (ins == I_STY) || (ins == I_STZ);
wire is_alurd = (ins == I_ORA) || (ins == I_AND) || (ins == I_EOR) || (ins == I_ADC) ||
                (ins == I_SBC) || (ins == I_CMP) || (ins == I_CPX) || (ins == I_CPY) ||
                (ins == I_CPZ) || (ins == I_LDA) || (ins == I_LDX) || (ins == I_LDY) ||
                (ins == I_LDZ) || (ins == I_BIT);
wire is_word  = (ins == I_INW) || (ins == I_DEW) || (ins == I_ASW) || (ins == I_ROW);
wire is_zpptr = (mode == M_INDX) || (mode == M_INDY) || (mode == M_INDZ);

wire is_q_alu = (ins == I_BIT) || (ins == I_LDA) || (ins == I_CMP) || (ins == I_ADC) || (ins == I_SBC) ||
                (ins == I_ORA) || (ins == I_EOR) || (ins == I_AND);
wire is_q_rmw = (ins == I_INC) || (ins == I_DEC) || (ins == I_ASL) || (ins == I_ROL) || (ins == I_LSR) ||
                (ins == I_ROR) || (ins == I_ASR);
wire qmem     = q_op && (is_q_alu || is_q_rmw || (ins == I_STA));
wire far_ptr  = far_op && (mode == M_INDZ);
wire q_now    = gs && (neg_cnt == 2'd2);
wire [31:0] Q = {Z, Y, X, A};

wire [7:0] P = {fN, fV, fE, 1'b0, fD, fI, fZ, fC};

wire [15:0] sp_dec = fE ? {SP[15:8], SP[7:0] - 8'd1} : SP - 16'd1;
wire [15:0] sp_inc = fE ? {SP[15:8], SP[7:0] + 8'd1} : SP + 16'd1;

wire take_int = (nmi_pend || (!irq_n && !fI)) && !map_inhibit && (neg_cnt == 2'd0) && !far_pfx;

logic branch_cond;
always_comb begin
	case (ins)
		I_BPL:   branch_cond = !fN;
		I_BMI:   branch_cond =  fN;
		I_BVC:   branch_cond = !fV;
		I_BVS:   branch_cond =  fV;
		I_BCC:   branch_cond = !fC;
		I_BCS:   branch_cond =  fC;
		I_BNE:   branch_cond = !fZ;
		I_BEQ:   branch_cond =  fZ;
		default: branch_cond = 1'b1;   // BRA
	endcase
end

wire [15:0] w      = {din, lo};
wire [15:0] rel8   = {{8{din[7]}}, din};

// ---------------------------------------------------------------- bus
logic [7:0] push_reg;
always_comb begin
	case (ins)
		I_PHA:   push_reg = A;
		I_PHX:   push_reg = X;
		I_PHY:   push_reg = Y;
		I_PHZ:   push_reg = Z;
		default: push_reg = P | 8'h10;   // PHP
	endcase
end

logic [7:0] store_reg;
always_comb begin
	case (ins)
		I_STA:   store_reg = A;
		I_STX:   store_reg = X;
		I_STY:   store_reg = Y;
		default: store_reg = Z;
	endcase
end

always_comb begin
	addr = PC;
	we   = 1'b0;
	dout = data;
	case (state)
		S_VECLO:              addr = vec;
		S_VECHI:              addr = vec | 16'd1;
		S_PTRLO, S_PTRHI:     addr = ptr;
		S_READ, S_READ2:      addr = ea;
		S_PTR2, S_PTR3:       addr = ptr;
		S_WRITE:    begin
			addr = ea; we = 1'b1;
			if (qmem) dout = (ins == I_STA) ? Q[qi*8 +: 8] : val32[qi*8 +: 8];
			else      dout = is_store ? store_reg : data;
		end
		S_WRITE2:   begin addr = ea; we = 1'b1; dout = datah; end
		S_PUSH_PCH: begin addr = SP; we = 1'b1; dout = PC[15:8]; end
		S_PUSH_PCL: begin addr = SP; we = 1'b1; dout = PC[7:0]; end
		S_PUSH_P:   begin addr = SP; we = 1'b1; dout = P | ((intr == INT_BRK) ? 8'h10 : 8'h00); end
		S_PUSH_REG: begin addr = SP; we = 1'b1; dout = push_reg; end
		S_PUSH_WLO: begin addr = SP; we = 1'b1; dout = data; end
		S_PUSH_WHI: begin addr = SP; we = 1'b1; dout = datah; end
		S_PULL_REG, S_PULL_P, S_PULL_PCL, S_PULL_PCH: addr = sp_inc;
		default: ;
	endcase
end

wire [11:0] map_off = addr[15] ? map_hi : map_lo;
assign mapped = map_en[addr[15:13]];
assign paddr  = mapped ? ({4'd0, addr} + {map_off, 8'd0}) : {4'd0, addr};
assign sync   = (state == S_FETCH) && !take_int;
assign far_sel  = ea_far && (state == S_READ || state == S_READ2 || state == S_WRITE || state == S_WRITE2);
assign far_addr = fea;

assign dbg_pc = PC;
assign dbg_a  = A;
assign dbg_x  = X;
assign dbg_y  = Y;
assign dbg_z  = Z;
assign dbg_b  = B;
assign dbg_p  = P;
assign dbg_sp = SP;

// ---------------------------------------------------------------- ALU
// ADC/SBC, binary and decimal (CMOS flag behaviour)
logic [7:0] adc_res, sbc_res;
logic       adc_c, adc_v, sbc_c, sbc_v;
logic [8:0] adc_bin, sbc_bin;
logic [5:0] adc_lo, adc_hi;
logic [4:0] sbc_lo;
always_comb begin
	adc_bin = {1'b0, A} + {1'b0, din} + {8'd0, fC};
	adc_lo  = {2'b0, A[3:0]} + {2'b0, din[3:0]} + {5'd0, fC};
	if (adc_lo > 6'd9) adc_lo = adc_lo + 6'd6;
	adc_hi  = {2'b0, A[7:4]} + {2'b0, din[7:4]} + {5'd0, (adc_lo > 6'd15)};
	if (fD) begin
		adc_v = ~(A[7] ^ din[7]) & (A[7] ^ adc_hi[3]);
		if (adc_hi > 6'd9) adc_hi = adc_hi + 6'd6;
		adc_c   = (adc_hi > 6'd15);
		adc_res = {adc_hi[3:0], adc_lo[3:0]};
	end else begin
		adc_v   = ~(A[7] ^ din[7]) & (A[7] ^ adc_bin[7]);
		adc_c   = adc_bin[8];
		adc_res = adc_bin[7:0];
	end

	sbc_bin = {1'b0, A} - {1'b0, din} - {8'd0, ~fC};
	sbc_lo  = {1'b0, A[3:0]} - {1'b0, din[3:0]} - {4'd0, ~fC};
	sbc_v   = (A[7] ^ din[7]) & (A[7] ^ sbc_bin[7]);
	sbc_c   = ~sbc_bin[8];
	sbc_res = sbc_bin[7:0];
	if (fD) begin
		if (sbc_bin[8]) sbc_res = sbc_res - 8'h60;
		if (sbc_lo[4])  sbc_res = sbc_res - 8'h06;
	end
end

// Read-modify-write unit: works on A (accumulator forms, decoded straight
// from din in S_FETCH) or on the byte just read from memory.
wire        rmw_acc = (state == S_FETCH);
wire  [7:0] rmw_in  = rmw_acc ? A : din;
wire  [7:0] rmw_op  = rmw_acc ? din : IR;
ins_t       rmw_ins;
assign      rmw_ins = rmw_acc ? f_ins : ins;
logic [7:0] rmw_res;
logic       rmw_c, rmw_setc, rmw_setnz, rmw_setz;
always_comb begin
	rmw_res   = rmw_in;
	rmw_c     = fC;
	rmw_setc  = 1'b0;
	rmw_setnz = 1'b1;
	rmw_setz  = 1'b0;
	case (rmw_ins)
		I_ASL: begin rmw_res = {rmw_in[6:0], 1'b0};      rmw_c = rmw_in[7]; rmw_setc = 1'b1; end
		I_ROL: begin rmw_res = {rmw_in[6:0], fC};        rmw_c = rmw_in[7]; rmw_setc = 1'b1; end
		I_LSR: begin rmw_res = {1'b0, rmw_in[7:1]};      rmw_c = rmw_in[0]; rmw_setc = 1'b1; end
		I_ROR: begin rmw_res = {fC, rmw_in[7:1]};        rmw_c = rmw_in[0]; rmw_setc = 1'b1; end
		I_ASR: begin rmw_res = {rmw_in[7], rmw_in[7:1]}; rmw_c = rmw_in[0]; rmw_setc = 1'b1; end
		I_INC: rmw_res = rmw_in + 8'd1;
		I_DEC: rmw_res = rmw_in - 8'd1;
		I_NEG: rmw_res = 8'd0 - rmw_in;
		I_TSB: begin rmw_res = rmw_in | A;  rmw_setnz = 1'b0; rmw_setz = 1'b1; end
		I_TRB: begin rmw_res = rmw_in & ~A; rmw_setnz = 1'b0; rmw_setz = 1'b1; end
		I_RMB: begin rmw_res = rmw_in & ~(8'd1 << rmw_op[6:4]); rmw_setnz = 1'b0; end
		I_SMB: begin rmw_res = rmw_in |  (8'd1 << rmw_op[6:4]); rmw_setnz = 1'b0; end
		default: ;
	endcase
end

// 16-bit read-modify-write (INW/DEW/ASW/ROW); operand is {din, lo}
logic [15:0] word_res;
logic        word_c;
always_comb begin
	word_c = fC;
	case (ins)
		I_INW:   word_res = w + 16'd1;
		I_DEW:   word_res = w - 16'd1;
		I_ASW:   begin word_res = {w[14:0], 1'b0}; word_c = w[15]; end
		default: begin word_res = {w[14:0], fC};   word_c = w[15]; end   // ROW
	endcase
end

// 32-bit (Q register) units.  m32 is the memory operand being assembled.
wire [31:0] m32 = {din, val32[31:8]};

ins_t        q_ins;
assign       q_ins = (state == S_FETCH) ? f_ins : ins;
wire  [31:0] q_in  = (state == S_FETCH) ? Q : m32;
logic [31:0] q_res;
logic        q_c, q_setc;
always_comb begin
	q_res = q_in; q_c = fC; q_setc = 1'b0;
	case (q_ins)
		I_ASL: begin q_res = {q_in[30:0], 1'b0};      q_c = q_in[31]; q_setc = 1'b1; end
		I_ROL: begin q_res = {q_in[30:0], fC};        q_c = q_in[31]; q_setc = 1'b1; end
		I_LSR: begin q_res = {1'b0, q_in[31:1]};      q_c = q_in[0];  q_setc = 1'b1; end
		I_ROR: begin q_res = {fC, q_in[31:1]};        q_c = q_in[0];  q_setc = 1'b1; end
		I_ASR: begin q_res = {q_in[31], q_in[31:1]};  q_c = q_in[0];  q_setc = 1'b1; end
		I_INC: q_res = q_in + 32'd1;
		I_DEC: q_res = q_in - 32'd1;
		I_NEG: q_res = 32'd0 - q_in;
		default: ;
	endcase
end

wire [32:0] q_add = {1'b0, Q} + {1'b0, m32} + {32'd0, fC};
wire [32:0] q_sub = {1'b0, Q} - {1'b0, m32} - {32'd0, ~fC};
wire [32:0] q_cmp = {1'b0, Q} - {1'b0, m32};

// ---------------------------------------------------------------- tasks
task automatic set_q(input logic [31:0] v);
	{Z, Y, X, A} <= v;
	fN <= v[31];
	fZ <= (v == 32'd0);
endtask

task automatic exec_q_alu;
	case (ins)
		I_LDA: set_q(m32);
		I_ORA: set_q(Q | m32);
		I_AND: set_q(Q & m32);
		I_EOR: set_q(Q ^ m32);
		I_ADC: begin set_q(q_add[31:0]); fC <= q_add[32];
		             fV <= (Q[31] ^ q_add[31]) & ~(Q[31] ^ m32[31]); end
		I_SBC: begin set_q(q_sub[31:0]); fC <= ~q_sub[32];
		             fV <= (Q[31] ^ q_sub[31]) & (Q[31] ^ m32[31]); end
		I_CMP: begin fN <= q_cmp[31]; fZ <= (q_cmp[31:0] == 32'd0); fC <= ~q_cmp[32]; end
		default: begin   // BITQ
			fZ <= ((Q & m32) == 32'd0); fN <= m32[31]; fV <= m32[30];
		end
	endcase
endtask

task automatic ea_step(input logic back3);
	if (ea_far) fea <= back3 ? fea - 28'd3 : fea + 28'd1;
	else        ea  <= back3 ? ea - 16'd3  : ea + 16'd1;
endtask

task automatic set_nz(input logic [7:0] v);
	fN <= v[7];
	fZ <= (v == 8'd0);
endtask

task automatic do_cmp(input logic [7:0] r, input logic [7:0] m);
	logic [8:0] d;
	d = {1'b0, r} - {1'b0, m};
	fC <= ~d[8];
	set_nz(d[7:0]);
endtask

// read-class instruction with operand m (== din), immediate or from memory
task automatic exec_alu(input logic [7:0] m, input logic imm);
	case (ins)
		I_ORA: begin A <= A | m; set_nz(A | m); end
		I_AND: begin A <= A & m; set_nz(A & m); end
		I_EOR: begin A <= A ^ m; set_nz(A ^ m); end
		I_ADC: begin A <= adc_res; set_nz(adc_res); fC <= adc_c; fV <= adc_v; end
		I_SBC: begin A <= sbc_res; set_nz(sbc_res); fC <= sbc_c; fV <= sbc_v; end
		I_CMP: do_cmp(A, m);
		I_CPX: do_cmp(X, m);
		I_CPY: do_cmp(Y, m);
		I_CPZ: do_cmp(Z, m);
		I_LDA: begin A <= m; set_nz(m); end
		I_LDX: begin X <= m; set_nz(m); end
		I_LDY: begin Y <= m; set_nz(m); end
		I_LDZ: begin Z <= m; set_nz(m); end
		I_BIT: begin
			fZ <= ((A & m) == 8'd0);
			if (!imm) begin fN <= m[7]; fV <= m[6]; end
		end
		default: ;
	endcase
endtask

task automatic set_flags(input logic [7:0] v);   // PLP / RTI: E and B untouched
	fN <= v[7]; fV <= v[6]; fD <= v[3]; fI <= v[2]; fZ <= v[1]; fC <= v[0];
endtask

task automatic goto_access;
	state <= is_store ? S_WRITE : S_READ;
endtask

// ---------------------------------------------------------------- FSM
always_ff @(posedge clk) begin
	nmi_d <= nmi_n;
	if (nmi_d && !nmi_n) nmi_pend <= 1'b1;

	if (reset) begin
		state <= S_VECLO;
		vec   <= 16'hFFFC;
		A <= '0; X <= '0; Y <= '0; Z <= '0; B <= '0;
		SP <= 16'h01FF;
		PC <= '0;
		{fN, fV, fD, fZ, fC} <= '0;
		fE <= 1'b1;
		fI <= 1'b1;
		IR <= 8'hEA;
		intr <= INT_NONE;
		nmi_pend <= 1'b0;
		nmi_d <= 1'b1;
		map_lo <= '0; map_hi <= '0; map_en <= '0;
		map_inhibit <= 1'b0;
		neg_cnt <= '0; far_pfx <= 1'b0; q_op <= 1'b0; far_op <= 1'b0; ea_far <= 1'b0; qi <= '0;
	end
	else if (hyp_load) begin
		// hypervisor trap results (the core holds the bus, so no ce this clk)
		A <= hyp_a; X <= hyp_x; Y <= hyp_y; fC <= hyp_c;
	end
	else if (pc_load) PC <= pc_val;
	else if (ce) begin
		case (state)
		S_VECLO: begin lo <= din; state <= S_VECHI; end
		S_VECHI: begin PC <= w; intr <= INT_NONE; state <= S_FETCH; end

		S_FETCH: begin
			if (take_int) begin
				intr <= nmi_pend ? INT_NMI : INT_IRQ;
				nmi_pend <= 1'b0;
				state <= S_PUSH_PCH;
			end
			else begin
				IR <= din;
				PC <= PC + 16'd1;
				state <= S_OP1;
				// prefixes apply to this instruction only
				q_op    <= q_now;
				far_op  <= gs && far_pfx;
				neg_cnt <= '0;
				far_pfx <= 1'b0;
				ea_far  <= 1'b0;
				qi      <= '0;
				if (f_mode == M_IMPL) begin
					state <= S_FETCH;
					case (f_ins)
						I_BRK: begin PC <= PC + 16'd2; intr <= INT_BRK; state <= S_PUSH_PCH; end
						I_PHA, I_PHX, I_PHY, I_PHZ, I_PHP: state <= S_PUSH_REG;
						I_PLA, I_PLX, I_PLY, I_PLZ:        state <= S_PULL_REG;
						I_PLP, I_RTI:                      state <= S_PULL_P;
						I_RTS:                             state <= S_PULL_PCL;
						I_ASL, I_ROL, I_LSR, I_ROR, I_ASR, I_INC, I_DEC, I_NEG: begin
							if (q_now) begin
								set_q(q_res);
								if (q_setc) fC <= q_c;
							end
							else begin
								A <= rmw_res;
								set_nz(rmw_res);
								if (rmw_setc) fC <= rmw_c;
								if (gs && f_ins == I_NEG) neg_cnt <= neg_cnt + 2'd1;
							end
						end
						I_INX: begin X <= X + 8'd1; set_nz(X + 8'd1); end
						I_INY: begin Y <= Y + 8'd1; set_nz(Y + 8'd1); end
						I_INZ: begin Z <= Z + 8'd1; set_nz(Z + 8'd1); end
						I_DEX: begin X <= X - 8'd1; set_nz(X - 8'd1); end
						I_DEY: begin Y <= Y - 8'd1; set_nz(Y - 8'd1); end
						I_DEZ: begin Z <= Z - 8'd1; set_nz(Z - 8'd1); end
						I_TAX: begin X <= A; set_nz(A); end
						I_TAY: begin Y <= A; set_nz(A); end
						I_TAZ: begin Z <= A; set_nz(A); end
						I_TXA: begin A <= X; set_nz(X); end
						I_TYA: begin A <= Y; set_nz(Y); end
						I_TZA: begin A <= Z; set_nz(Z); end
						I_TBA: begin A <= B; set_nz(B); end
						I_TAB: B <= A;
						I_TSX: begin X <= SP[7:0];  set_nz(SP[7:0]);  end
						I_TSY: begin Y <= SP[15:8]; set_nz(SP[15:8]); end
						I_TXS: SP[7:0]  <= X;
						I_TYS: SP[15:8] <= Y;
						I_CLC: fC <= 1'b0;
						I_SEC: fC <= 1'b1;
						I_CLI: fI <= 1'b0;
						I_SEI: fI <= 1'b1;
						I_CLD: fD <= 1'b0;
						I_SED: fD <= 1'b1;
						I_CLV: fV <= 1'b0;
						I_CLE: fE <= 1'b0;
						I_SEE: fE <= 1'b1;
						I_MAP: begin
							map_lo <= {X[3:0], A};
							map_hi <= {Z[3:0], Y};
							map_en <= {Z[7:4], X[7:4]};
							map_inhibit <= 1'b1;
						end
						I_EOM: begin
							map_inhibit <= 1'b0;
							if (gs) begin
								far_pfx <= 1'b1;
								if (neg_cnt == 2'd2) neg_cnt <= 2'd2;
							end
						end
						default: ;
					endcase
				end
			end
		end

		S_OP1: begin
			lo <= din;
			PC <= PC + 16'd1;
			case (mode)
				M_IMM: begin
					if (ins == I_RTS) state <= S_PULL_PCL;
					else begin exec_alu(din, 1'b1); state <= S_FETCH; end
				end
				M_ZP:     begin ea <= {B, din};     goto_access(); end
				M_ZPX:    begin ea <= {B, din + X}; goto_access(); end
				M_ZPY:    begin ea <= {B, din + Y}; goto_access(); end
				M_INDX:   begin ptr <= {B, din + X}; state <= S_PTRLO; end
				M_INDY,
				M_INDZ:   begin ptr <= {B, din};     state <= S_PTRLO; end
				M_INDSPY: begin ptr <= SP + {8'd0, din}; state <= S_PTRLO; end
				M_REL: begin
					if (branch_cond) PC <= PC + 16'd1 + rel8;
					state <= S_FETCH;
				end
				M_ZPREL:  begin ea <= {B, din}; state <= S_READ; end
				default:  state <= S_OP2;
			endcase
		end

		S_OP2: begin
			PC <= PC + 16'd1;
			case (mode)
				M_ABS: begin
					if (ins == I_JMP) begin PC <= w; state <= S_FETCH; end
					else if (ins == I_JSR) begin PC <= PC; ea <= w; state <= S_PUSH_PCH; end
					else begin ea <= w; goto_access(); end
				end
				M_ABSX: begin ea <= w + {8'd0, X}; goto_access(); end
				M_ABSY: begin ea <= w + {8'd0, Y}; goto_access(); end
				M_IND16, M_IND16X: begin
					ptr <= (mode == M_IND16X) ? w + {8'd0, X} : w;
					if (ins == I_JSR) PC <= PC;
					state <= S_PTRLO;
				end
				M_REL16: begin
					state <= S_FETCH;
					if (ins == I_BSR) begin PC <= PC; ea <= PC + w; state <= S_PUSH_PCH; end
					else if (branch_cond) PC <= PC + w;
				end
				default: begin   // M_IMM16: PHW #nnnn
					data <= lo; datah <= din; state <= S_PUSH_WLO;
				end
			endcase
		end

		S_PTRLO: begin
			lo  <= din;
			ptr <= (is_zpptr && !far_ptr) ? {ptr[15:8], ptr[7:0] + 8'd1} : ptr + 16'd1;
			state <= S_PTRHI;
		end

		S_PTR2: begin fp2 <= din; ptr <= ptr + 16'd1; state <= S_PTR3; end
		S_PTR3: begin
			// Q operations other than LDQ do not index with Z (Z is part of Q)
			fea    <= {din[3:0], fp2, fp1, lo} + ((qmem && ins != I_LDA) ? 28'd0 : {20'd0, Z});
			ea_far <= 1'b1;
			goto_access();
		end

		S_PTRHI: begin
			case (mode)
				M_INDX:   begin ea <= w;               goto_access(); end
				M_INDZ: begin
					if (far_ptr) begin fp1 <= din; ptr <= ptr + 16'd1; state <= S_PTR2; end
					else begin
						ea <= w + ((qmem && ins != I_LDA) ? 16'd0 : {8'd0, Z});
						goto_access();
					end
				end
				M_INDY,
				M_INDSPY: begin ea <= w + {8'd0, Y};   goto_access(); end
				default: begin   // (nnnn) / (nnnn,X)
					if (ins == I_JSR) begin ea <= w; state <= S_PUSH_PCH; end
					else begin PC <= w; state <= S_FETCH; end
				end
			endcase
		end

		S_READ: begin
			if (mode == M_ZPREL) begin data <= din; state <= S_BBREL; end
			else if (qmem) begin
				val32 <= m32;
				qi    <= qi + 2'd1;
				if (qi != 2'd3) ea_step(1'b0);
				else if (is_q_alu) begin exec_q_alu(); state <= S_FETCH; end
				else begin
					val32 <= q_res;
					fN <= q_res[31];
					fZ <= (q_res == 32'd0);
					if (q_setc) fC <= q_c;
					ea_step(1'b1);
					state <= S_WRITE;
				end
			end
			else if (is_alurd) begin exec_alu(din, 1'b0); state <= S_FETCH; end
			else if (is_word || ins == I_PHW) begin
				lo <= din; ea <= ea + 16'd1; state <= S_READ2;
			end
			else begin
				data <= rmw_res;
				if (rmw_setnz) set_nz(rmw_res);
				if (rmw_setz)  fZ <= ((din & A) == 8'd0);
				if (rmw_setc)  fC <= rmw_c;
				state <= S_WRITE;
			end
		end

		S_READ2: begin
			if (ins == I_PHW) begin data <= lo; datah <= din; state <= S_PUSH_WLO; end
			else begin
				data  <= word_res[7:0];
				datah <= word_res[15:8];
				fN <= word_res[15];
				fZ <= (word_res == 16'd0);
				fC <= word_c;
				ea <= ea - 16'd1;
				state <= S_WRITE;
			end
		end

		S_WRITE: begin
			if (qmem) begin
				qi <= qi + 2'd1;
				ea_step(1'b0);
				if (qi == 2'd3) state <= S_FETCH;
			end
			else if (is_word) begin ea <= ea + 16'd1; state <= S_WRITE2; end
			else state <= S_FETCH;
		end

		S_WRITE2: state <= S_FETCH;

		S_BBREL: begin
			PC <= PC + 16'd1;
			if (data[IR[6:4]] == IR[7]) PC <= PC + 16'd1 + rel8;
			state <= S_FETCH;
		end

		S_PUSH_PCH: begin SP <= sp_dec; state <= S_PUSH_PCL; end
		S_PUSH_PCL: begin
			SP <= sp_dec;
			if (intr != INT_NONE) state <= S_PUSH_P;
			else begin PC <= ea; state <= S_FETCH; end
		end
		S_PUSH_P: begin
			SP  <= sp_dec;
			fI  <= 1'b1;
			fD  <= 1'b0;
			vec <= (intr == INT_NMI) ? 16'hFFFA : 16'hFFFE;
			state <= S_VECLO;
		end
		S_PUSH_REG: begin SP <= sp_dec; state <= S_FETCH; end
		S_PUSH_WLO: begin SP <= sp_dec; state <= S_PUSH_WHI; end
		S_PUSH_WHI: begin SP <= sp_dec; state <= S_FETCH; end

		S_PULL_REG: begin
			SP <= sp_inc;
			set_nz(din);
			case (ins)
				I_PLA:   A <= din;
				I_PLX:   X <= din;
				I_PLY:   Y <= din;
				default: Z <= din;
			endcase
			state <= S_FETCH;
		end
		S_PULL_P: begin
			SP <= sp_inc;
			set_flags(din);
			state <= (ins == I_RTI) ? S_PULL_PCL : S_FETCH;
		end
		S_PULL_PCL: begin SP <= sp_inc; lo <= din; state <= S_PULL_PCH; end
		S_PULL_PCH: begin
			SP <= sp_inc;
			PC <= (ins == I_RTS) ? w + 16'd1 : w;
			if (ins == I_RTS && mode == M_IMM)
				SP <= fE ? {SP[15:8], sp_inc[7:0] + IR_arg} : sp_inc + {8'd0, IR_arg};
			state <= S_FETCH;
		end

		default: state <= S_FETCH;
		endcase
	end
end

endmodule
