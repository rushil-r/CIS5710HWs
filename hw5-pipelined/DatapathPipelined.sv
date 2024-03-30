`timescale 1ns / 1ns

// registers are 32 bits in RV32
`define REG_SIZE 31:0

// insns are 32 bits in RV32IM
`define INSN_SIZE 31:0

// RV opcodes are 7 bits
`define OPCODE_SIZE 6:0

`ifndef RISCV_FORMAL
`include "../hw2b/cla.sv"
`include "../hw3-singlecycle/RvDisassembler.sv"
`include "../hw4-multicycle/divider_unsigned_pipelined.sv"
`endif

module Disasm #(
    byte PREFIX = "D"
) (
    input wire [31:0] insn,
    output wire [(8*32)-1:0] disasm
);
  // synthesis translate_off
  // this code is only for simulation, not synthesis
  string disasm_string;
  always_comb begin
    disasm_string = rv_disasm(insn);
  end
  // HACK: get disasm_string to appear in GtkWave, which can apparently show only wire/logic. Also,
  // string needs to be reversed to render correctly.
  genvar i;
  for (i = 3; i < 32; i = i + 1) begin : gen_disasm
    assign disasm[((i+1-3)*8)-1-:8] = disasm_string[31-i];
  end
  assign disasm[255-:8] = PREFIX;
  assign disasm[247-:8] = ":";
  assign disasm[239-:8] = " ";
  // synthesis translate_on
endmodule

module RegFile (
    input logic [4:0] rd,
    input logic [`REG_SIZE] rd_data,
    input logic [4:0] rs1,
    output logic [`REG_SIZE] rs1_data,
    input logic [4:0] rs2,
    output logic [`REG_SIZE] rs2_data,

    input logic clk,
    input logic we,
    input logic rst
);
  localparam int NumRegs = 32;
  // use latergenvar i;
  logic [`REG_SIZE] regs[NumRegs];

  // TODO: your code here

endmodule

/**
 * This enum is used to classify each cycle as it comes through the Writeback stage, identifying
 * if a valid insn is present or, if it is a stall cycle instead, the reason for the stall. The
 * enum values are mutually exclusive: only one should be set for any given cycle. These values
 * are compared against the trace-*.json files to ensure that the datapath is running with the
 * correct timing.
 *
 * You will need to set these values at various places within your pipeline, and propagate them
 * through the stages until they reach Writeback where they can be checked.
 */
typedef enum {
  /** invalid value, this should never appear after the initial reset sequence completes */
  CYCLE_INVALID = 0,
  /** a stall cycle that arose from the initial reset signal */
  CYCLE_RESET = 1,
  /** not a stall cycle, a valid insn is in Writeback */
  CYCLE_NO_STALL = 2,
  /** a stall cycle that arose from a taken branch/jump */
  CYCLE_TAKEN_BRANCH = 4,

  // the values below are only needed in HW5B

  /** a stall cycle that arose from a load-to-use stall */
  CYCLE_LOAD2USE = 8,
  /** a stall cycle that arose from a div/rem-to-use stall */
  CYCLE_DIV2USE  = 16,
  /** a stall cycle that arose from a fence.i insn */
  CYCLE_FENCEI   = 32
} cycle_status_e;

/** state at the start of Decode stage */
typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;
} stage_decode_t;


module DatapathPipelined (
    input wire clk,
    input wire rst,
    output logic [`REG_SIZE] pc_to_imem,
    input wire [`INSN_SIZE] insn_from_imem,
    // dmem is read/write
    output logic [`REG_SIZE] addr_to_dmem,
    input wire [`REG_SIZE] load_data_from_dmem,
    output logic [`REG_SIZE] store_data_to_dmem,
    output logic [3:0] store_we_to_dmem,

    output logic halt,

    // The PC of the insn currently in Writeback. 0 if not a valid insn.
    output logic [`REG_SIZE] trace_writeback_pc,
    // The bits of the insn currently in Writeback. 0 if not a valid insn.
    output logic [`INSN_SIZE] trace_writeback_insn,
    // The status of the insn (or stall) currently in Writeback. See cycle_status_e enum for valid values.
    output cycle_status_e trace_writeback_cycle_status
);


  // opcodes - see section 19 of RiscV spec
  localparam bit [`OPCODE_SIZE] OpcodeLoad = 7'b00_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeStore = 7'b01_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeBranch = 7'b11_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeJalr = 7'b11_001_11;
  localparam bit [`OPCODE_SIZE] OpcodeMiscMem = 7'b00_011_11;
  localparam bit [`OPCODE_SIZE] OpcodeJal = 7'b11_011_11;

  localparam bit [`OPCODE_SIZE] OpcodeRegImm = 7'b00_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeRegReg = 7'b01_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeEnviron = 7'b11_100_11;

  localparam bit [`OPCODE_SIZE] OpcodeAuipc = 7'b00_101_11;
  localparam bit [`OPCODE_SIZE] OpcodeLui = 7'b01_101_11;

  // cycle counter, not really part of any stage but useful for orienting within GtkWave
  // do not rename this as the testbench uses this value
  logic [`REG_SIZE] cycles_current;
  always_ff @(posedge clk) begin
    if (rst) begin
      cycles_current <= 0;
    end else begin
      cycles_current <= cycles_current + 1;
    end
  end

  /***************/
  /* FETCH STAGE */
  /***************/

  logic [`REG_SIZE] f_pc_current, f_pc_next;
  wire [`REG_SIZE] f_insn;
  cycle_status_e f_cycle_status;

  // program counter
  logic flag_div;
  always_ff @(posedge clk) begin
    if (rst) begin
      f_pc_current   <= 32'd0;
      // NB: use CYCLE_NO_STALL since this is the value that will persist after the last reset cycle
      f_cycle_status <= CYCLE_NO_STALL;
    end else begin
      f_cycle_status <= CYCLE_NO_STALL;
      f_pc_current   <= f_pc_current + 4;
    end
  end
  // send PC to imem
  assign pc_to_imem = f_pc_current;
  assign f_insn = insn_from_imem;

  // Here's how to disassemble an insn into a string you can view in GtkWave.
  // Use PREFIX to provide a 1-character tag to identify which stage the insn comes from.
  wire [255:0] f_disasm;
  Disasm #(
      .PREFIX("F")
  ) disasm_0fetch (
      .insn  (f_insn),
      .disasm(f_disasm)
  );

  /****************/
  /* DECODE STAGE */
  /****************/

  // this shows how to package up state in a `struct packed`, and how to pass it between stages
  stage_decode_t decode_state;
  always_ff @(posedge clk) begin
    if (rst) begin
      decode_state <= '{pc: 0, insn: 0, cycle_status: CYCLE_RESET};
    end else begin
      begin
        decode_state <= '{pc: f_pc_current, insn: f_insn, cycle_status: f_cycle_status};
      end
    end
  end
  wire [255:0] d_disasm;
  Disasm #(
      .PREFIX("D")
  ) disasm_1decode (
      .insn  (decode_state.insn),
      .disasm(d_disasm)
  );

  // TODO: your code here, though you will also need to modify some of the code above

  /*******************/
  /*    EXECUTION    */
  /*******************/
  logic [0:0] regfile_we;
  logic [`REG_SIZE] data_rd;
  logic [`REG_SIZE] data_rs1;
  logic [`REG_SIZE] data_rs2;
  logic [4:0] regfile_rd;
  logic [4:0] regfile_rs1;
  logic [4:0] regfile_rs2;

  // components of the instruction
  wire [6:0] insn_funct7;
  wire [4:0] insn_rs2;
  wire [4:0] insn_rs1;
  wire [2:0] insn_funct3;
  wire [4:0] insn_rd;
  wire [`OPCODE_SIZE] insn_opcode;
  // split R-type instruction - see section 2.2 of RiscV spec
  assign {insn_funct7, insn_rs2, insn_rs1, insn_funct3, insn_rd, insn_opcode} = insn_from_imem;

  // setup for I, S, B & J type instructions
  // I - short immediates and loads
  wire [11:0] imm_i;
  assign imm_i = insn_from_imem[31:20];
  wire [ 4:0] imm_shamt = insn_from_imem[24:20];

  // S - stores
  wire [11:0] imm_s;
  assign imm_s[11:5] = insn_funct7, imm_s[4:0] = insn_rd;

  // B - conditionals
  wire [12:0] imm_b;
  assign {imm_b[12], imm_b[10:5]} = insn_funct7, {imm_b[4:1], imm_b[11]} = insn_rd, imm_b[0] = 1'b0;

  // J - unconditional jumps
  wire [20:0] imm_j;
  assign {imm_j[20], imm_j[10:1], imm_j[11], imm_j[19:12], imm_j[0]} = {
    insn_from_imem[31:12], 1'b0
  };

  // U - 20-bit immediate
  wire [19:0] imm_u;
  assign imm_u = insn_from_imem[31:12];

  wire [`REG_SIZE] imm_i_sext = {{20{imm_i[11]}}, imm_i[11:0]};
  wire [`REG_SIZE] imm_s_sext = {{20{imm_s[11]}}, imm_s[11:0]};
  wire [`REG_SIZE] imm_b_sext = {{19{imm_b[12]}}, imm_b[12:0]};
  wire [`REG_SIZE] imm_j_sext = {{11{imm_j[20]}}, imm_j[20:0]};
  wire [`REG_SIZE] imm_u_sext = {{12{imm_u[19]}}, imm_u[19:0]};

  wire insn_lui = insn_opcode == OpcodeLui;
  wire insn_auipc = insn_opcode == OpcodeAuipc;
  wire insn_jal = insn_opcode == OpcodeJal;
  wire insn_jalr = insn_opcode == OpcodeJalr;

  wire insn_beq = insn_opcode == OpcodeBranch && insn_from_imem[14:12] == 3'b000;
  wire insn_bne = insn_opcode == OpcodeBranch && insn_from_imem[14:12] == 3'b001;
  wire insn_blt = insn_opcode == OpcodeBranch && insn_from_imem[14:12] == 3'b100;
  wire insn_bge = insn_opcode == OpcodeBranch && insn_from_imem[14:12] == 3'b101;
  wire insn_bltu = insn_opcode == OpcodeBranch && insn_from_imem[14:12] == 3'b110;
  wire insn_bgeu = insn_opcode == OpcodeBranch && insn_from_imem[14:12] == 3'b111;

  wire insn_lb = insn_opcode == OpcodeLoad && insn_from_imem[14:12] == 3'b000;
  wire insn_lh = insn_opcode == OpcodeLoad && insn_from_imem[14:12] == 3'b001;
  wire insn_lw = insn_opcode == OpcodeLoad && insn_from_imem[14:12] == 3'b010;
  wire insn_lbu = insn_opcode == OpcodeLoad && insn_from_imem[14:12] == 3'b100;
  wire insn_lhu = insn_opcode == OpcodeLoad && insn_from_imem[14:12] == 3'b101;

  wire insn_sb = insn_opcode == OpcodeStore && insn_from_imem[14:12] == 3'b000;
  wire insn_sh = insn_opcode == OpcodeStore && insn_from_imem[14:12] == 3'b001;
  wire insn_sw = insn_opcode == OpcodeStore && insn_from_imem[14:12] == 3'b010;

  wire insn_addi = insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b000;
  wire insn_slti = insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b010;
  wire insn_sltiu = insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b011;
  wire insn_xori = insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b100;
  wire insn_ori = insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b110;
  wire insn_andi = insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b111;

  wire insn_slli = (insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b001
     && insn_from_imem[31:25] == 7'd0);
  wire insn_srli = (insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b101
     && insn_from_imem[31:25] == 7'd0);
  wire insn_srai = (insn_opcode == OpcodeRegImm && insn_from_imem[14:12] == 3'b101
     && insn_from_imem[31:25] == 7'b0100000);

  wire insn_add = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b000
     && insn_from_imem[31:25] == 7'd0);
  wire insn_sub = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b000
     && insn_from_imem[31:25] == 7'b0100000);
  wire insn_sll = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b001
     && insn_from_imem[31:25] == 7'd0);
  wire insn_slt = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b010
     && insn_from_imem[31:25] == 7'd0);
  wire insn_sltu = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b011
     && insn_from_imem[31:25] == 7'd0);
  wire insn_xor = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b100
     && insn_from_imem[31:25] == 7'd0);
  wire insn_srl = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b101
     && insn_from_imem[31:25] == 7'd0);
  wire insn_sra  = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b101
     && insn_from_imem[31:25] == 7'b0100000);
  wire insn_or = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b110
     && insn_from_imem[31:25] == 7'd0);
  wire insn_and = (insn_opcode == OpcodeRegReg && insn_from_imem[14:12] == 3'b111
     && insn_from_imem[31:25] == 7'd0);

  wire insn_mul    = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b000);
  wire insn_mulh   = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b001);
  wire insn_mulhsu = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b010);
  wire insn_mulhu  = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b011);
  wire insn_div    = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b100);
  wire insn_divu   = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b101);
  wire insn_rem    = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b110);
  wire insn_remu   = (insn_opcode == OpcodeRegReg && insn_from_imem[31:25] == 7'd1
     && insn_from_imem[14:12] == 3'b111);

  wire insn_ecall = insn_opcode == OpcodeEnviron && insn_from_imem[31:7] == 25'd0;
  wire insn_fence = insn_opcode == OpcodeMiscMem;

  // TODO: the testbench requires that your register file instance is named `rf`

  logic [31:0] temp_addr;
  logic [31:0] temp_load_casing;
  logic illegal_insn;

  wire [31:0] cla_sum;
  wire [31:0] cla_sum_reg;
  wire [31:0] cla_diff_reg;
  wire [31:0] div_u_rem_reg;
  wire [31:0] div_u_qot_reg;
  wire [31:0] div_rem_reg;
  wire [31:0] div_qot_reg;
  wire [31:0] div_rem_reg_bn;
  wire [31:0] div_qot_reg_bn;
  logic [3:0] store_we_to_dmem_temp;
  logic [31:0] store_data_to_dmem_temp;

  RegFile rf (
      .rd(insn_rd),
      .rd_data(data_rd),
      .rs1(insn_rs1),
      .rs1_data(data_rs1),
      .rs2(insn_rs2),
      .rs2_data(data_rs2),
      .clk(clk),
      .we(regfile_we),
      .rst(rst)
  );

  cla cla_ops (
      .a  (data_rs1),
      .b  (imm_i_sext),
      .cin(1'b0),
      .sum(cla_sum)
  );
  cla cla_reg_add (
      .a  (data_rs1),
      .b  (data_rs2),
      .cin(1'b0),
      .sum(cla_sum_reg)
  );
  cla cla_reg_sub (
      .a  (data_rs1),
      .b  ((~data_rs2) + 1'b1),
      .cin(1'b0),
      .sum(cla_diff_reg)
  );
  divider_unsigned_pipelined div_u_alu (
      .clk(clk),
      .rst(rst),
      .i_dividend(data_rs1),
      .i_divisor(data_rs2),
      .o_remainder(div_u_rem_reg),
      .o_quotient(div_u_qot_reg)
  );

  divider_unsigned_pipelined div_sr_alu_n (
      .clk(clk),
      .rst(rst),
      .i_dividend((({32{data_rs1[31]}} ^ data_rs1) + {31'b0, data_rs1[31]})),
      .i_divisor((({32{data_rs2[31]}} ^ data_rs2) + {31'b0, data_rs2[31]})),
      .o_remainder(div_rem_reg),
      .o_quotient(div_qot_reg)
  );

  always_comb begin
    halt = 1'b0;
    // set as default, but make sure to change if illegal/default-case/failure
    illegal_insn = 1'b0;
    if (!((flag_div == 0) && (insn_div || insn_divu || insn_rem || insn_remu))) begin
      f_pc_next = f_pc_current + 4;
    end
    regfile_we = 1'b0;
    //f_pc_next = f_pc_current + 4;
    temp_addr = 'd0;
    addr_to_dmem = 'd0;
    store_we_to_dmem = 4'b0000;
    if (insn_ecall) begin
      // ecall
      halt = 1'b1;
    end
    case (insn_opcode)
      OpcodeMiscMem: begin
        f_pc_next = ((f_pc_current + 4) & 32'b11111111111111111111111111111100);
        addr_to_dmem = (addr_to_dmem & 32'b11111111111111111111111111111100);
      end
      OpcodeLui: begin
        regfile_we = 1'b1;
        data_rd = {{imm_u[19:0]}, 12'b0};  // 20-bit bitshifted left by 12
      end
      OpcodeAuipc: begin
        regfile_we = 1'b1;
        data_rd = f_pc_current + {{imm_u[19:0]}, 12'b0};  // 20-bit bitshifted left by 12
      end
      OpcodeRegImm: begin
        regfile_we = 1'b1;  //re-enable regfile when changing data_rd
        case (insn_from_imem[14:12])
          3'b000: begin
            //addi
            data_rd = cla_ops.sum;
          end
          3'b001: begin
            //slli
            data_rd = data_rs1 << imm_shamt;  //imm_shamt for shift_amount
          end
          3'b010: begin
            //slti
            data_rd = ($signed(data_rs1) < $signed(imm_i_sext)) ? 1 : 0;
          end
          3'b011: begin
            //stliu
            data_rd = data_rs1 < imm_i_sext ? 1 : 0;
          end
          3'b100: begin
            //xori
            data_rd = data_rs1 ^ imm_i_sext;
          end
          3'b101: begin
            if (insn_from_imem[31:25] == 7'd0) begin
              //srli
              data_rd = data_rs1 >> imm_shamt;
            end else begin
              //srai
              data_rd = $signed(data_rs1) >>> imm_shamt;
            end
          end
          3'b110: begin
            //ori
            data_rd = data_rs1 | imm_i_sext;
          end
          3'b111: begin
            //andi
            data_rd = data_rs1 & imm_i_sext;
          end
          default: begin
            regfile_we   = 1'b0;
            illegal_insn = 1'b1;
          end
        endcase
      end
      OpcodeBranch: begin
        regfile_we = 1'b0;
        // formula for SEXT(targ12<<1) = {{19{imm_b[11]}}, (imm_b<<1)}
        case (insn_from_imem[14:12])
          3'b000: begin
            //beq
            if (data_rs1 == data_rs2) begin
              f_pc_next = f_pc_current + imm_b_sext;
            end
          end
          3'b001: begin
            //bne
            if (data_rs1 != data_rs2) begin
              f_pc_next = f_pc_current + imm_b_sext;
            end
          end
          3'b100: begin
            if ($signed(data_rs1) < $signed(data_rs2)) begin
              f_pc_next = f_pc_current + imm_b_sext;
            end
          end
          3'b101: begin
            //bge
            if ($signed(data_rs1) >= $signed(data_rs2)) begin
              f_pc_next = f_pc_current + imm_b_sext;
            end
          end
          3'b110: begin
            //bltu
            if (data_rs1 < data_rs2) begin
              f_pc_next = f_pc_current + imm_b_sext;
            end
          end
          3'b111: begin
            //bgeu
            if (data_rs1 >= data_rs2) begin
              f_pc_next = f_pc_current + imm_b_sext;
            end
          end
          default: begin
            illegal_insn = 1'b1;
            regfile_we   = 1'b0;
          end
        endcase
      end
      OpcodeRegReg: begin
        case (insn_from_imem[14:12])
          3'b000: begin
            regfile_we = 1'b1;
            if (insn_from_imem[31:25] == 7'd0) begin
              //add
              data_rd = cla_reg_add.sum;
            end else if (insn_from_imem[31:25] == 7'b0100000) begin
              //sub
              data_rd = cla_reg_sub.sum;
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //mul
              data_rd = (data_rs1 * data_rs2) & 32'h00000000ffffffff;
            end
          end
          3'b001: begin
            regfile_we = 1'b1;

            if (insn_from_imem[31:25] == 7'd0) begin
              //sll
              data_rd = data_rs1 << (data_rs2[4:0]);
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //mulh
              logic [63:0] inter_mulh;
              inter_mulh = ($signed(data_rs1) * $signed(data_rs2));
              data_rd = inter_mulh[63:32];
            end
          end
          3'b010: begin
            regfile_we = 1'b1;

            if (insn_from_imem[31:25] == 7'd0) begin
              //slt
              data_rd = $signed(data_rs1) < $signed(data_rs2) ? 1 : 0;
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //mulhsu
              logic [63:0] inter_mulhsu;
              inter_mulhsu = $signed(data_rs1) * $signed({1'b0, data_rs2});
              data_rd = (inter_mulhsu[63:32]);
              //still fw it somehow at the start
              //* data_rs1[31] * (|data_rs2));
              //data_rd = inter_mulhsu[63:32];
            end
          end
          3'b011: begin
            regfile_we = 1'b1;

            if (insn_from_imem[31:25] == 7'd0) begin
              //sltu
              data_rd = data_rs1 < data_rs2 ? 1 : 0;
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //mulhu
              logic [63:0] inter_mulhu;
              inter_mulhu = ($unsigned(data_rs1) * $unsigned(data_rs2));
              data_rd = inter_mulhu[63:32];
            end
          end
          3'b100: begin
            regfile_we = 1'b1;

            if (insn_from_imem[31:25] == 7'd0) begin
              //xor
              data_rd = data_rs1 ^ data_rs2;
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //div
              //  //div IN PROGRESS
              // if(flag_div == 0) begin
              //   regfile_we = 1'b0;
              //   // Compute absolute value of rs1_data
              //   abs_rs1_data = data_rs1[31] ? (~data_rs1 + 1'b1) : data_rs1;
              //   // Compute absolute value of rs2_data
              //   abs_rs2_data = data_rs2[31] ? (~data_rs2 + 1'b1) : data_rs2;
              //   data_rs1 = abs_rs1_data;
              //   data_rs2 = abs_rs2_data;
              // end else if (flag_div == 1) begin
              //   regfile_we = 1'b1;
              //   if (data_rs1[31] != data_rs2[31]) begin
              //     data_rd = ~div_qot_reg + 1'b1;
              //   end else begin
              //     data_rd = div_qot_reg;  // case falls here (should be 3)
              //   end
              // end
              if (data_rs2 == 0) begin
                data_rd = 32'hFFFF_FFFF;  // div by 0 error
              end else if (data_rs1[31] != data_rs2[31]) begin
                data_rd = ~div_qot_reg + 1'b1;
                // data_rd = ((~div_qot_reg)+(1'b1*(|(~div_qot_reg)))+(&div_qot_reg * ({32{1'b1}})));
                //(((~div_qot_reg) | ({{31{&div_qot_reg}}, 1'b0})) + 1'b1);
              end else begin
                data_rd = div_qot_reg;  // case falls here (should be 3)
              end
            end
          end
          3'b101: begin
            if (insn_from_imem[31:25] == 7'd0) begin
              //srl
              regfile_we = 1'b1;
              data_rd = data_rs1 >> (data_rs2[4:0]);
            end else if (insn_from_imem[31:25] == 7'b0100000) begin
              //sra
              regfile_we = 1'b1;
              data_rd = $signed(data_rs1) >>> $signed((data_rs2[4:0]));
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //divu
              if (flag_div == 1) begin
                regfile_we = 1'b1;  //enable writing back to RF
                if (data_rs2 == 0) begin
                  data_rd = 32'hFFFF_FFFF;  // div by 0 error
                end else begin
                  data_rd = div_u_qot_reg;  //we can write the quotient
                end
              end else begin
                regfile_we = 1'b0;  //disable writing back to RF
              end
            end
          end
          3'b110: begin
            regfile_we = 1'b1;
            if (insn_from_imem[31:25] == 7'd0) begin
              //or
              data_rd = data_rs1 | data_rs2;
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //rem
              if (data_rs1[31]) begin
                data_rd = ((~div_rem_reg) + 1'b1);
              end else begin
                data_rd = div_rem_reg;
              end
              // if (flag_div) begin
              //   flag_div = 1'b0;
              // end else begin
              //   flag_div = 1'b1;
              // end
            end
          end
          3'b111: begin
            regfile_we = 1'b1;
            if (insn_from_imem[31:25] == 7'd0) begin
              //and
              data_rd = data_rs1 & data_rs2;
            end else if (insn_from_imem[31:25] == 7'b0000001) begin
              //remu
              data_rd = div_u_rem_reg;
              // if (flag_div) begin
              //   flag_div = 1'b0;
              // end else begin
              //   flag_div = 1'b1;
              // end
            end
          end
          default: begin
            illegal_insn = 1'b1;
            regfile_we   = 1'b0;
          end
        endcase
      end
      OpcodeJal: begin
        regfile_we = 1'b1;
        data_rd = f_pc_current + 4;
        f_pc_next = f_pc_current + imm_j_sext;
      end
      OpcodeJalr: begin
        regfile_we = 1'b1;
        data_rd = f_pc_current + 4;
        f_pc_next = ((data_rs1 + imm_i_sext) & (32'b11111111111111111111111111111110));
      end
      OpcodeLoad: begin
        regfile_we = 1'b1;
        // addr_to_dmem = {{temp_load_casing[31:2]}, 2'b00};
        case (insn_from_imem[14:12])
          3'b000: begin
            // lb loads an 8-bit value from mem, SEXT to 32 bits, then stores in rd
            // Ensure addres is aligned
            temp_addr = data_rs1 + imm_i_sext;
            case (temp_addr[1:0])
              2'b00:
              // aligned so we grab the first byte
              data_rd = {
                {24{load_data_from_dmem[7]}}, load_data_from_dmem[7:0]
              };
              2'b01:
              // mod 1 -> grab the second byte
              data_rd = {
                {24{load_data_from_dmem[15]}}, load_data_from_dmem[15:8]
              };
              2'b10:
              // mod 2 -> grab the third byte
              data_rd = {
                {24{load_data_from_dmem[23]}}, load_data_from_dmem[23:16]
              };
              2'b11:
              // mod 3 -> grab the 4th byte
              data_rd = {
                {24{load_data_from_dmem[31]}}, load_data_from_dmem[31:24]
              };
              default: begin
                illegal_insn = 1'b1;
                regfile_we   = 1'b0;
              end
            endcase
          end
          3'b001: begin
            // lh loads a 16-bit value from mem, SEXT to 32-bits, then stores in rd
            // Align to the nearest lower half-word boundary
            // Assuming memory access returns a 32-bit word
            temp_addr = data_rs1 + imm_i_sext;
            case (temp_addr[1])
              1'b0: begin
                // Aligned access so we grab the first 16 bits
                data_rd = {{16{load_data_from_dmem[15]}}, load_data_from_dmem[15:0]};
              end
              1'b1: begin
                // Unaligned access, half-word crosses 32-bit word boundary
                // Grab the second 16 bits
                data_rd = {{16{load_data_from_dmem[31]}}, load_data_from_dmem[31:16]};
              end
              default: begin
                illegal_insn = 1'b1;
                regfile_we   = 1'b0;
              end
            endcase
          end
          3'b010: begin
            // lw loads a 32-bit value from memory into rd
            // Calculate memory address to load from
            temp_addr = data_rs1 + imm_i_sext;
            data_rd   = load_data_from_dmem;  // Data loaded from memory
          end
          3'b100: begin
            // lbu loads an 8-bit value from mem, zext to 32 bits, then stores in rd
            // Sign-extend based on the lowest 2 bits of the address
            temp_addr = data_rs1 + imm_i_sext;
            case (temp_addr[1:0])
              2'b00: data_rd = {24'b0, load_data_from_dmem[7:0]};  //mul of 4 (mod 0)
              2'b01: data_rd = {24'b0, load_data_from_dmem[15:8]};  //mod 1
              2'b10: data_rd = {24'b0, load_data_from_dmem[23:16]};  // mod 2
              2'b11: data_rd = {24'b0, load_data_from_dmem[31:24]};  // mod 3
              default: begin
                regfile_we   = 1'b0;
                illegal_insn = 1'b1;
              end
            endcase
          end
          3'b101: begin
            // lhu loads a 16-bit value from mem, 0-fills to 32-bits, then stores in rd
            // Assuming memory access returns a 32-bit word
            temp_addr = data_rs1 + imm_i_sext;
            case (temp_addr[1])
              1'b0: begin
                // Aligned access
                data_rd = {16'b0, load_data_from_dmem[15:0]};
              end
              1'b1: begin
                // Unaligned access, half-word crosses 32-bit word boundary
                // Grab the second 16 bits
                data_rd = {16'b0, load_data_from_dmem[31:16]};
              end
              default: begin
                illegal_insn = 1'b1;
                regfile_we   = 1'b0;
              end
            endcase
          end
          default: begin
            temp_addr = 'd0;
            illegal_insn = 1'b1;
            regfile_we = 1'b0;
          end
        endcase
        addr_to_dmem = {{temp_addr[31:2]}, 2'b00};
      end
      OpcodeStore: begin
        // temp_addr = data_rs1 + imm_s_sext;
        temp_addr = data_rs1 + imm_s_sext;
        if (insn_sb) begin
          //store byte
          // addr_to_dmem = {temp_addr[31:2], 2'b00};
          case (temp_addr[1:0])
            //aligned
            2'b00: begin
              store_data_to_dmem[7:0] = data_rs2[7:0];
              store_we_to_dmem = 4'b0001;
            end
            2'b01: begin
              store_data_to_dmem[15:8] = data_rs2[7:0];
              //mod 1
              store_we_to_dmem = 4'b0010;
            end
            2'b10: begin
              store_data_to_dmem[23 : 16] = data_rs2[7:0];
              //mod 2
              store_we_to_dmem = 4'b0100;
            end
            //mod3
            2'b11: begin
              store_data_to_dmem[31 : 24] = data_rs2[7:0];
              store_we_to_dmem = 4'b1000;
            end
            default: begin
              regfile_we   = 1'b0;
              illegal_insn = 1'b1;
            end
          endcase
        end else if (insn_sh) begin
          //store half
          temp_addr = data_rs1 + imm_s_sext;
          // addr_to_dmem = {temp_add[31:2], 2'b00};
          //allignment
          case (temp_addr[1])
            1'b0: begin
              //aligned
              store_data_to_dmem[15:0] = data_rs2[15:0];
              store_we_to_dmem = 4'b0011;
            end
            1'b1: begin
              // mod 1
              store_data_to_dmem[31:16] = data_rs2[15:0];
              store_we_to_dmem = 4'b1100;
            end
            default: begin
              regfile_we   = 1'b0;
              illegal_insn = 1'b1;
            end
          endcase
        end else if (insn_sw) begin
          //store word -> assuming fullt aligned
          store_we_to_dmem = 4'b1111;
          temp_addr = data_rs1 + imm_s_sext;
          // addr_to_dmem = {temp_add[31:2], 2'b00};
          store_data_to_dmem[31:0] = data_rs2;
        end else begin
          temp_addr = 'd0;
          regfile_we = 1'b0;
          illegal_insn = 1'b1;
        end
        addr_to_dmem = {{temp_addr[31:2]}, 2'b00};
      end
      default: begin
      end
    endcase
    // f_pc_next = f_pc_current+4
    //^^^^^ relocated to inside case statements to allow for branching logic
  end

endmodule

module MemorySingleCycle #(
    parameter int NUM_WORDS = 512
) (
    // rst for both imem and dmem
    input wire rst,

    // clock for both imem and dmem. The memory reads/writes on @(negedge clk)
    input wire clk,

    // must always be aligned to a 4B boundary
    input wire [`REG_SIZE] pc_to_imem,

    // the value at memory location pc_to_imem
    output logic [`REG_SIZE] insn_from_imem,

    // must always be aligned to a 4B boundary
    input wire [`REG_SIZE] addr_to_dmem,

    // the value at memory location addr_to_dmem
    output logic [`REG_SIZE] load_data_from_dmem,

    // the value to be written to addr_to_dmem, controlled by store_we_to_dmem
    input wire [`REG_SIZE] store_data_to_dmem,

    // Each bit determines whether to write the corresponding byte of store_data_to_dmem to memory location addr_to_dmem.
    // E.g., 4'b1111 will write 4 bytes. 4'b0001 will write only the least-significant byte.
    input wire [3:0] store_we_to_dmem
);

  // memory is arranged as an array of 4B words
  logic [`REG_SIZE] mem[NUM_WORDS];

  initial begin
    $readmemh("mem_initial_contents.hex", mem, 0);
  end

  always_comb begin
    // memory addresses should always be 4B-aligned
    assert (pc_to_imem[1:0] == 2'b00);
    assert (addr_to_dmem[1:0] == 2'b00);
  end

  localparam int AddrMsb = $clog2(NUM_WORDS) + 1;
  localparam int AddrLsb = 2;

  always @(negedge clk) begin
    if (rst) begin
    end else begin
      insn_from_imem <= mem[{pc_to_imem[AddrMsb:AddrLsb]}];
    end
  end

  always @(negedge clk) begin
    if (rst) begin
    end else begin
      if (store_we_to_dmem[0]) begin
        mem[addr_to_dmem[AddrMsb:AddrLsb]][7:0] <= store_data_to_dmem[7:0];
      end
      if (store_we_to_dmem[1]) begin
        mem[addr_to_dmem[AddrMsb:AddrLsb]][15:8] <= store_data_to_dmem[15:8];
      end
      if (store_we_to_dmem[2]) begin
        mem[addr_to_dmem[AddrMsb:AddrLsb]][23:16] <= store_data_to_dmem[23:16];
      end
      if (store_we_to_dmem[3]) begin
        mem[addr_to_dmem[AddrMsb:AddrLsb]][31:24] <= store_data_to_dmem[31:24];
      end
      // dmem is "read-first": read returns value before the write
      load_data_from_dmem <= mem[{addr_to_dmem[AddrMsb:AddrLsb]}];
    end
  end
endmodule

/* This design has just one clock for both processor and memory. */
module RiscvProcessor (
    input wire clk,
    input wire rst,
    output logic halt,
    output wire [`REG_SIZE] trace_writeback_pc,
    output wire [`INSN_SIZE] trace_writeback_insn,
    output cycle_status_e trace_writeback_cycle_status
);

  wire [`INSN_SIZE] insn_from_imem;
  wire [`REG_SIZE] pc_to_imem, mem_data_addr, mem_data_loaded_value, mem_data_to_write;
  wire [3:0] mem_data_we;

  MemorySingleCycle #(
      .NUM_WORDS(8192)
  ) the_mem (
      .rst                (rst),
      .clk                (clk),
      // imem is read-only
      .pc_to_imem         (pc_to_imem),
      .insn_from_imem     (insn_from_imem),
      // dmem is read-write
      .addr_to_dmem       (mem_data_addr),
      .load_data_from_dmem(mem_data_loaded_value),
      .store_data_to_dmem (mem_data_to_write),
      .store_we_to_dmem   (mem_data_we)
  );

  DatapathPipelined datapath (
      .clk(clk),
      .rst(rst),
      .pc_to_imem(pc_to_imem),
      .insn_from_imem(insn_from_imem),
      .addr_to_dmem(mem_data_addr),
      .store_data_to_dmem(mem_data_to_write),
      .store_we_to_dmem(mem_data_we),
      .load_data_from_dmem(mem_data_loaded_value),
      .halt(halt),
      .trace_writeback_pc(trace_writeback_pc),
      .trace_writeback_insn(trace_writeback_insn),
      .trace_writeback_cycle_status(trace_writeback_cycle_status)
  );

endmodule
