// MEGA65 hypervisor mode.
//
// Outside the hypervisor, writing $D640+n (n = 0-63) is a trap: the CPU's
// registers are saved in $D640-$D649 and the CPU continues in hypervisor
// mode at $8000 + 4 * n, with A / X / Y / Z unchanged, B = $BF (zero page
// $BF00), SP = $BEFF in page mode (E set) and interrupts held off.  While in
// the hypervisor, $8000-$BFFF is the hypervisor's own 16K RAM and $D000-$DFFF
// is always I/O (the core does that); everything else keeps the user's
// memory map.  $D640-$D67E then read and write the save area (the hypervisor
// puts its results there), and writing $D67F returns to the program with the
// registers from the save area.
//
//   $D640 A  $D641 X  $D642 Y  $D643 Z  $D644 B  $D645 SPL  $D646 SPH
//   $D647 P  $D648 PCL  $D649 PCH  (as on the MEGA65)
//   $D670-$D673  size of the image mounted as the SD card (read only)
//   $D674        bit 0 an image is mounted, bit 1 it is read only, bit 6 a new
//                image was mounted, bit 7 the machine was reset (both cleared
//                by writing $D674): the hypervisor RAM survives resets, so the
//                program uses these to start over
//   $D67E        the trap number (read only)
//
// The hypervisor program itself is software (rtl/hyppo), loaded into the
// hypervisor RAM when the FPGA is configured.

module m65_hyp (
	input  logic        clk,
	input  logic        reset,

	input  logic        reg_we,        // write to $D640-$D67F completed this clk
	input  logic  [5:0] reg_addr,
	input  logic  [7:0] reg_din,
	output logic  [7:0] reg_dout,

	input  logic  [7:0] cpu_a, cpu_x, cpu_y, cpu_z, cpu_b, cpu_p,
	input  logic [15:0] cpu_sp, cpu_pc,

	output logic        hyp,           // in hypervisor mode
	output logic        busy,          // hold the CPU (entry / exit in progress)
	output logic        load,          // load the CPU's registers (one clk, while held)
	output logic  [7:0] ld_a, ld_x, ld_y, ld_z, ld_b, ld_p,
	output logic [15:0] ld_sp, ld_pc,

	input  logic [31:0] img_size,
	input  logic        img_present,
	input  logic        img_ro,
	input  logic        img_mounted     // a new image in the SD card slot (one clk)
);

logic [7:0] sv [16];
logic [5:0] trap_n;
typedef enum logic [1:0] { Y_IDLE, Y_ENTER, Y_EXIT } ystate_t;
ystate_t st;
logic    wait1;
logic    fresh, changed;

// the bus stays held through the clk the registers load in, so the first
// fetch at the new PC starts with the memory already addressed there
assign busy = (st != Y_IDLE) || load;

always_ff @(posedge clk) begin
	load <= 1'b0;
	if (img_mounted) changed <= 1'b1;
	if (reset) begin
		hyp <= 1'b0; st <= Y_IDLE; wait1 <= 1'b0; fresh <= 1'b1;
	end
	else begin
		case (st)
			Y_IDLE: if (reg_we) begin
				if (!hyp) begin
					// trap: save the program's registers
					sv[0] <= cpu_a; sv[1] <= cpu_x; sv[2] <= cpu_y; sv[3] <= cpu_z; sv[4] <= cpu_b;
					sv[5] <= cpu_sp[7:0]; sv[6] <= cpu_sp[15:8]; sv[7] <= cpu_p;
					sv[8] <= cpu_pc[7:0]; sv[9] <= cpu_pc[15:8];
					trap_n <= reg_addr; st <= Y_ENTER; wait1 <= 1'b1;
				end
				else if (reg_addr == 6'h3F) begin st <= Y_EXIT; wait1 <= 1'b1; end
				else if (reg_addr < 6'd16) sv[reg_addr[3:0]] <= reg_din;
				else if (reg_addr == 6'h34) begin fresh <= 1'b0; changed <= 1'b0; end
			end
			Y_ENTER: begin
				if (wait1) wait1 <= 1'b0;
				else begin
					ld_a <= sv[0]; ld_x <= sv[1]; ld_y <= sv[2]; ld_z <= sv[3];
					ld_b <= 8'hBF; ld_sp <= 16'hBEFF;
					ld_p <= {sv[7][7:6], 1'b1, 1'b0, 1'b0, 1'b1, sv[7][1:0]};    // E and I set, D clear
					ld_pc <= 16'h8000 + {8'd0, trap_n, 2'b00};
					load <= 1'b1; hyp <= 1'b1; st <= Y_IDLE;
				end
			end
			Y_EXIT: begin
				if (wait1) wait1 <= 1'b0;
				else begin
					ld_a <= sv[0]; ld_x <= sv[1]; ld_y <= sv[2]; ld_z <= sv[3]; ld_b <= sv[4];
					ld_sp <= {sv[6], sv[5]}; ld_p <= sv[7]; ld_pc <= {sv[9], sv[8]};
					load <= 1'b1; hyp <= 1'b0; st <= Y_IDLE;
				end
			end
			default: st <= Y_IDLE;
		endcase
	end
end

always_comb begin
	reg_dout = 8'h00;
	if (hyp) begin
		if (reg_addr < 6'd16) reg_dout = sv[reg_addr[3:0]];
		else case (reg_addr)
			6'h30: reg_dout = img_size[7:0];
			6'h31: reg_dout = img_size[15:8];
			6'h32: reg_dout = img_size[23:16];
			6'h33: reg_dout = img_size[31:24];
			6'h34: reg_dout = {fresh, changed, 4'd0, img_ro, img_present};
			6'h3E: reg_dout = {2'b00, trap_n};
			default: ;
		endcase
	end
end

endmodule
