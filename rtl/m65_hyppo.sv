// A small stand-in for the MEGA65 hypervisor's DOS (the "hyppo" traps).
//
// On a MEGA65, STA $D640 with a function number in A enters the hypervisor,
// which runs the function and returns with results in A / X / Y and the
// carry flag (set = success, clear = failure with an error code in A).  Here
// the core holds the CPU while this unit does the work, then loads those
// registers into the CPU.
//
// There is no SD card file system: the one file the program can open is the
// file mounted in the OSD as the "data file" (for example SPACE.SCP).
// findfile succeeds for any name while a file is mounted; readfile delivers
// it 512 bytes at a time into the SD sector buffer ($FFD6E00), as the real
// hypervisor does.  The function numbers and register conventions follow
// src/hyppo/dos.asm of the MEGA65 core (MEGA65/mega65-core, GPL).
//
//   $00 getversion        A.X = 1.03, Y.Z = 1.03
//   $02 getdefaultdrive   A = 0          $04 getcurrentdrive  A = 0
//   $06 selectdrive       ok             $0C chdir            ok, A = 0
//   $18 openfile          A = file descriptor 0
//   $1A readfile          X/Y = bytes read (512, less at the end, 0 at EOF + C clear)
//   $20 closefile, $22 closeall, $2E setname, $3C cdrootdir     ok
//   $34 findfile          ok while a data file is mounted, else $88 file not found
//   anything else         fails with $82 not implemented

module m65_hyppo (
	input  logic        clk,
	input  logic        reset,

	input  logic        trap,          // STA $D640 completed this clk (CPU is held from the next clk)
	input  logic  [7:0] fn,            // the value written (function number)
	input  logic  [7:0] cpu_a, cpu_x, cpu_y,
	output logic        busy,          // hold the CPU
	output logic        load,          // load the results into the CPU (one clk, while held)
	output logic  [7:0] res_a, res_x, res_y,
	output logic        res_c,

	// the data file (MiSTer block interface, 256 byte blocks, two per request)
	input  logic        img_mounted,
	input  logic [31:0] img_size,
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	input  logic        sd_ack,
	output logic        buf_clear      // not used yet
);

typedef enum logic [1:0] { H_IDLE, H_READ, H_DONE } hstate_t;
hstate_t     st;
logic        present = 1'b0;
logic [31:0] size;
logic        opened, found;
logic [31:0] pos, remain;
logic        ack_seen;

assign busy = (st != H_IDLE);
assign buf_clear = 1'b0;

task automatic finish(input logic [7:0] a, input logic [7:0] x, input logic [7:0] y, input logic c);
	res_a <= a; res_x <= x; res_y <= y; res_c <= c;
	st <= H_DONE;
endtask

always_ff @(posedge clk) begin
	load <= 1'b0;
	if (img_mounted) begin
		present <= (img_size != 32'd0);
		size    <= img_size;
		opened  <= 1'b0;
		found   <= 1'b0;
	end

	if (reset) begin
		st <= H_IDLE; sd_rd <= 1'b0; opened <= 1'b0; found <= 1'b0;
	end
	else case (st)
		H_IDLE: if (trap) begin
			case (fn & 8'h7E)
				8'h00: finish(8'h01, 8'h03, 8'h01, 1'b1);                         // getversion
				8'h02, 8'h04: finish(8'h00, cpu_x, cpu_y, 1'b1);                  // default / current drive
				8'h06, 8'h22, 8'h2E, 8'h3C: finish(cpu_a, cpu_x, cpu_y, 1'b1);    // selectdrive, closeall, setname, cdrootdir
				8'h0C: finish(8'h00, cpu_x, cpu_y, 1'b1);                         // chdir
				8'h34: begin                                                      // findfile
					found <= present;
					if (present) finish(cpu_a, cpu_x, cpu_y, 1'b1);
					else         finish(8'h88, cpu_x, cpu_y, 1'b0);
				end
				8'h18: begin                                                      // openfile
					if (present && found) begin
						opened <= 1'b1; pos <= '0; remain <= size;
						finish(8'h00, cpu_x, cpu_y, 1'b1);
					end
					else finish(8'h88, cpu_x, cpu_y, 1'b0);
				end
				8'h1A: begin                                                      // readfile
					if (!opened) finish(8'h89, cpu_x, cpu_y, 1'b0);
					else if (remain == 32'd0) finish(8'h00, 8'h00, 8'h00, 1'b0);   // end of file
					else begin
						sd_lba <= {8'd0, pos[31:8]}; sd_rd <= 1'b1; ack_seen <= 1'b0;
						st <= H_READ;
					end
				end
				8'h20: begin opened <= 1'b0; finish(cpu_a, cpu_x, cpu_y, 1'b1); end   // closefile
				default: finish(8'h82, cpu_x, cpu_y, 1'b0);                       // not implemented
			endcase
		end

		H_READ: begin
			if (sd_ack) begin sd_rd <= 1'b0; ack_seen <= 1'b1; end
			else if (ack_seen) begin
				pos <= pos + 32'd512;
				if (remain >= 32'd512) begin
					remain <= remain - 32'd512;
					finish(cpu_a, 8'h00, 8'h02, 1'b1);
				end
				else begin
					remain <= '0;
					finish(cpu_a, remain[7:0], {7'd0, remain[8]}, 1'b1);
				end
			end
		end

		H_DONE: begin load <= 1'b1; st <= H_IDLE; end
		default: st <= H_IDLE;
	endcase
end

endmodule
