// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Shared definitions for the merv core.  Kept to `defines and localparams
// (no packages/structs) so that the RTL can be read by Verilator, Vivado and
// Yosys alike.
`ifndef MERV_DEFS_SVH
`define MERV_DEFS_SVH

// ALU operations, decoded by alu_ctrl() into the ALU control word.
`define ALU_ADD   4'd0
`define ALU_SUB   4'd1
`define ALU_PASSA 4'd2
`define ALU_SLT   4'd3
`define ALU_SLTU  4'd4
`define ALU_XOR   4'd5
`define ALU_REVA  4'd6
`define ALU_ANDN  4'd7
`define ALU_OR    4'd8
`define ALU_AND   4'd9
`define ALU_PASSB 4'd10
`define ALU_MIN   4'd11
`define ALU_MAX   4'd12
`define ALU_MINU  4'd13
`define ALU_MAXU  4'd14
`define ALU_ZERO  4'd15

// ALU control word fields.
`define ALU_CTRL_W 7
`define ALU_C_SUB  0
`define ALU_C_SUM  1
`define ALU_C_SET  2
`define ALU_C_SETU 3
`define ALU_C_LOP  4

// Logic unit operations.
`define LOP_XOR   3'd0
`define LOP_OR    3'd1
`define LOP_AND   3'd2
`define LOP_ANDN  3'd3
`define LOP_PASSA 3'd4
`define LOP_PASSB 3'd5
`define LOP_REVA  3'd6
`define LOP_ZERO  3'd7

// Privilege levels.
`define PRIV_U 2'd0
`define PRIV_S 2'd1
`define PRIV_M 2'd3

// Memory access types.
`define ACC_FETCH 3'd0
`define ACC_LOAD  3'd1
`define ACC_STORE 3'd2
`define ACC_LR    3'd3
`define ACC_SC    3'd4
`define ACC_AMO   3'd5

// Register file layout, word offsets within the register window at the top
// of the F-RAM (0x1e00): GPR banks and the CSRs that live in the RAM.
`define RF_BANK_F   7'h20
`define RF_MSCRATCH 7'h40
`define RF_MEPC     7'h41
`define RF_MCAUSE   7'h42
`define RF_MTVAL    7'h43
`define RF_MTVEC    7'h44
`define RF_SSCRATCH 7'h45
`define RF_SEPC     7'h46
`define RF_SCAUSE   7'h47
`define RF_STVAL    7'h48
`define RF_STVEC    7'h49
`define RF_SATP     7'h4a
`define RF_FEPC     7'h4b
`define RF_FTVAL    7'h4c
`define RF_FPADDR   7'h4d
`define RF_SCRATCH  7'h4e

// Exception causes.
`define EXC_INSN_MISALIGNED  5'd0
`define EXC_INSN_ACCESS      5'd1
`define EXC_ILLEGAL          5'd2
`define EXC_BREAKPOINT       5'd3
`define EXC_LOAD_MISALIGNED  5'd4
`define EXC_LOAD_ACCESS      5'd5
`define EXC_STORE_MISALIGNED 5'd6
`define EXC_STORE_ACCESS     5'd7
`define EXC_ECALL_U          5'd8
`define EXC_INSN_PAGE        5'd12
`define EXC_LOAD_PAGE        5'd13
`define EXC_STORE_PAGE       5'd15

// F mode event causes.
`define FEV_RESET     3'd0
`define FEV_ITLB      3'd1
`define FEV_LTLB      3'd2
`define FEV_STLB      3'd3
`define FEV_CYWRAP    3'd4
`define FEV_IRWRAP    3'd5
`define FEV_EMULATE   3'd6
`define FEV_SFENCE    3'd7

`endif
