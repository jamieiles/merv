// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// merv: a small RV32IMA core with M, S and U modes plus the firmware assisted
// F mode, see docs/merv-arch.md.
//
// Instructions execute through a state machine with every state boundary
// registered.  To keep the LUT count down the datapath is built around the
// single ALU: its two 4:1 input multiplexers select from the architectural
// registers and almost every register loads only from the ALU output, using
// pass operations to move values around.  The F-RAM, the GPRs (two banks)
// and the CSRs that are only accessed by software or on traps share one
// block RAM (MervRAM), the remaining CSR state is in flops.  Memory accesses
// go through a single AXI4 manager with one transaction in flight, or the
// private F-RAM when in F mode.
`include "MervDefs.svh"

module MervCore #(
    parameter int TLB_ENTRIES = 4,
    parameter int NATIVE_AMO  = 1,
    parameter int HW_DIV      = 1,
    // Shift in a single cycle rather than by 8 or 1 bits per cycle.
    parameter int BARREL_SHIFT = 0,
    parameter     FFW_INIT    = ""
) (
    input  logic        clk,
    input  logic        reset,
    // M mode entry point after F mode firmware initialization, normally tied
    // to a constant.
    input  logic [31:0] reset_vector,
    // AXI4 manager, single beat transactions, no IDs.
    output logic [31:0] axi_awaddr,
    output logic [ 2:0] axi_awsize,
    output logic [ 2:0] axi_awprot,
    output logic        axi_awvalid,
    input  logic        axi_awready,
    output logic [31:0] axi_wdata,
    output logic [ 3:0] axi_wstrb,
    output logic        axi_wvalid,
    input  logic        axi_wready,
    // verilator lint_off UNUSEDSIGNAL
    input  logic [ 1:0] axi_bresp,
    // verilator lint_on UNUSEDSIGNAL
    input  logic        axi_bvalid,
    output logic        axi_bready,
    output logic [31:0] axi_araddr,
    output logic [ 2:0] axi_arsize,
    output logic [ 2:0] axi_arprot,
    output logic        axi_arvalid,
    input  logic        axi_arready,
    input  logic [31:0] axi_rdata,
    // verilator lint_off UNUSEDSIGNAL
    input  logic [ 1:0] axi_rresp,
    // verilator lint_on UNUSEDSIGNAL
    input  logic        axi_rvalid,
    output logic        axi_rready,
    // Interrupts, synchronous to clk.
    input  logic        meip,
    input  logic        seip,
    input  logic        mtip,
    input  logic        msip,
    // Status/trace for simulation.
    output logic        halted,
    output logic        trace_retire,
    output logic        trace_trap,
    output logic        trace_fevent,
    output logic [31:0] trace_pc,
    output logic [31:0] trace_insn,
    output logic [ 2:0] trace_priv,
    output logic        trace_rd_we,
    output logic [ 4:0] trace_rd,
    output logic [31:0] trace_rd_val,
    output logic [ 5:0] trace_cause,
    // Debug: the most recent M/S trap.
    output logic [ 5:0] dbg_trap_cause,
    output logic [31:0] dbg_trap_epc,
    output logic [31:0] dbg_trap_tval
);

    // ------------------------------------------------------------------
    // States
    // ------------------------------------------------------------------
    localparam logic [5:0]
        S_FETCH   = 6'd0,
        S_TLB1    = 6'd1,
        S_TLB2    = 6'd2,
        S_ACC     = 6'd3,
        S_AR      = 6'd4,
        S_R       = 6'd5,
        S_AW      = 6'd6,
        S_B       = 6'd7,
        S_FR1     = 6'd8,
        S_FR2     = 6'd9,
        S_DECODE  = 6'd10,
        S_DECODE2 = 6'd11,
        S_EXEC    = 6'd12,
        S_XLATE   = 6'd13,
        S_BRANCH  = 6'd14,
        S_JUMP    = 6'd15,
        S_WB      = 6'd16,
        S_MUL     = 6'd17,
        S_DIV     = 6'd18,
        S_AMO_ALU = 6'd19,
        S_SHIFT   = 6'd20,
        S_LDEXT   = 6'd21,
        S_CSR1    = 6'd22,
        S_CSR2    = 6'd23,
        S_CSR3    = 6'd24,
        S_CSR4    = 6'd25,
        S_CSR5    = 6'd26,
        S_TRAP1   = 6'd27,
        S_TRAP2   = 6'd28,
        S_TRAP3   = 6'd29,
        S_TRAP4   = 6'd30,
        S_FENT1   = 6'd31,
        S_FENT2   = 6'd32,
        S_FENT3   = 6'd33,
        S_XRET1   = 6'd34,
        S_XRET2   = 6'd35,
        S_XRET3   = 6'd36,
        S_FRET1   = 6'd37,
        S_FRET2   = 6'd38,
        S_FRET3   = 6'd39,
        S_FRET4   = 6'd40,
        S_AMO_CMP = 6'd41,
        S_HALT    = 6'd42,
        S_TRAP0   = 6'd43,
        S_FENT0   = 6'd44,
        S_AMO_PICK = 6'd45;
    localparam int S_COUNT = 46;

    // The state is held one-hot so that state tests are single flops and
    // the next state logic is a set of independent equations.
    logic [S_COUNT-1:0] st, nst;
    // The next state without trap/F event overrides, used for the registered
    // ALU control.  Traps and F events enter through S_TRAP0/S_FENT0 which
    // don't use the ALU so the control is a don't care in that cycle.
    logic [S_COUNT-1:0] nst_n;

    // Sources of the trap/F event value written to (f)tval.
    localparam logic [1:0] TV_ADDR = 2'd0, TV_IR = 2'd1, TV_PC = 2'd2,
                           TV_ZERO = 2'd3;

    // ------------------------------------------------------------------
    // Architectural and sequencing state
    // ------------------------------------------------------------------
    logic [31:0] pc, ir, imm;
    logic [ 1:0] priv;
    logic        is_f;
    logic [31:0] addr;        // VA of the current access, staging for tval
    logic [31:0] pa;
    logic [ 2:0] acc;
    logic [ 1:0] size;
    logic [31:0] wdata;
    logic [ 3:0] wstrb;
    logic [31:0] result;
    logic [ 4:0] trap_cause;
    logic        trap_intr;
    logic [ 1:0] tval_src;
    logic [ 2:0] fev_cause;
    logic        taken;
    logic        jump_misaligned;
    logic        pc_done;
    logic        wb_we;
    logic        xl_tlb;      // the access is translated
    logic        aw_done, w_done;
    logic        resv_valid;
    logic [29:0] resv_addr;
    logic [ 4:0] shamt;
    logic        shamt_zero;      // registered shamt == 0
    logic        shift_fill, shift_rev, shift_ld;

    // Flop CSR state.
    logic        m_sie, m_mie, m_spie, m_mpie, m_spp, m_mprv, m_sum, m_mxr;
    logic        m_tvm, m_tw, m_tsr;
    logic [ 1:0] m_mpp;
    logic [15:0] medeleg;
    logic [ 2:0] mideleg;     // SEI, STI, SSI
    logic [ 5:0] mie_r;       // MEI, SEI, MTI, STI, MSI, SSI
    logic        ssip, stip, seip_sw;
    logic [ 2:0] mcounteren, scounteren;
    logic        satp_mode;
    logic [31:0] mcycle, minstret;
    logic        instret_written;
    logic [ 1:0] f_pprv;
    logic        f_berr, f_cywrap, f_irwrap, f_sfpend;
    logic [ 2:0] f_cause;
    logic        finj_valid;
    logic [ 4:0] finj_cause;
    logic [ 3:0] ftlbidx;
    logic [21:0] ftlbhi;

    // ------------------------------------------------------------------
    // Decode (registered in S_DECODE)
    // ------------------------------------------------------------------
    logic [ 3:0] d_alu_op;
    logic        d_a_pc, d_b_imm;
    logic        d_alu, d_shift, d_branch, d_jal, d_jalr, d_load, d_store;
    logic        d_amo, d_lr, d_sc, d_csr, d_mul, d_div, d_ecall, d_ebreak;
    logic        d_mret, d_sret, d_wfi, d_sfence, d_fret, d_illegal;
    logic        d_rd_we;
    logic [ 1:0] d_size;
    logic        d_ld_unsigned;

    wire [6:0] opcode = ir[6:0];
    wire [2:0] funct3 = ir[14:12];
    wire [6:0] funct7 = ir[31:25];
    wire [4:0] rd     = ir[11:7];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];
    wire [4:0] funct5 = ir[31:27];

    // Instruction formats, the immediate register is also used to hold the
    // cause of a pending trap.
    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{20{ir[31]}}, ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'b0};
    wire [31:0] imm_j = {{12{ir[31]}}, ir[19:12], ir[20], ir[30:21], 1'b0};
    wire [31:0] imm_z = {27'b0, rs1};

    always_ff @(posedge clk) begin
        if (st[S_DECODE]) begin
            d_alu     <= 1'b0;
            d_shift   <= 1'b0;
            d_branch  <= 1'b0;
            d_jal     <= 1'b0;
            d_jalr    <= 1'b0;
            d_load    <= 1'b0;
            d_store   <= 1'b0;
            d_amo     <= 1'b0;
            d_lr      <= 1'b0;
            d_sc      <= 1'b0;
            d_csr     <= 1'b0;
            d_mul     <= 1'b0;
            d_div     <= 1'b0;
            d_ecall   <= 1'b0;
            d_ebreak  <= 1'b0;
            d_mret    <= 1'b0;
            d_sret    <= 1'b0;
            d_wfi     <= 1'b0;
            d_sfence  <= 1'b0;
            d_fret    <= 1'b0;
            d_illegal <= 1'b0;
            d_a_pc    <= 1'b0;
            d_b_imm   <= 1'b1;
            d_alu_op  <= `ALU_ADD;
            d_size    <= funct3[1:0];
            d_ld_unsigned <= funct3[2];
            d_rd_we   <= rd != 5'b0 && opcode != 7'b1100011 &&
                         opcode != 7'b0100011 && opcode != 7'b0001111 &&
                         !(opcode == 7'b1110011 && funct3 == 3'b000);

            case (opcode)
                7'b0110111: begin  // LUI
                    d_alu    <= 1'b1;
                    d_alu_op <= `ALU_PASSB;
                end
                7'b0010111: begin  // AUIPC
                    d_alu  <= 1'b1;
                    d_a_pc <= 1'b1;
                end
                7'b1101111: d_jal <= 1'b1;
                7'b1100111: begin  // JALR
                    d_jalr    <= funct3 == 3'b000;
                    d_illegal <= funct3 != 3'b000;
                end
                7'b1100011: begin  // Branches
                    d_branch  <= funct3[2:1] != 2'b01;
                    d_illegal <= funct3[2:1] == 2'b01;
                    d_b_imm   <= 1'b0;
                end
                7'b0000011: begin  // Loads
                    d_load    <= funct3 != 3'b011 && funct3 != 3'b110 &&
                                 funct3 != 3'b111;
                    d_illegal <= funct3 == 3'b011 || funct3 == 3'b110 ||
                                 funct3 == 3'b111;
                end
                7'b0100011: begin  // Stores
                    d_store   <= funct3[2:1] == 2'b00 || funct3 == 3'b010;
                    d_illegal <= !(funct3[2:1] == 2'b00 || funct3 == 3'b010);
                end
                7'b0010011: begin  // OP-IMM
                    case (funct3)
                        3'b001: begin
                            d_shift   <= funct7 == 7'b0;
                            d_illegal <= funct7 != 7'b0;
                        end
                        3'b101: begin
                            d_shift   <= funct7 == 7'b0 || funct7 == 7'b0100000;
                            d_illegal <= !(funct7 == 7'b0 || funct7 == 7'b0100000);
                        end
                        default: d_alu <= 1'b1;
                    endcase
                    case (funct3)
                        3'b010:  d_alu_op <= `ALU_SLT;
                        3'b011:  d_alu_op <= `ALU_SLTU;
                        3'b100:  d_alu_op <= `ALU_XOR;
                        3'b110:  d_alu_op <= `ALU_OR;
                        3'b111:  d_alu_op <= `ALU_AND;
                        default: d_alu_op <= `ALU_ADD;
                    endcase
                end
                7'b0110011: begin  // OP
                    d_b_imm <= 1'b0;
                    if (funct7 == 7'b0000001) begin
                        d_mul <= ~funct3[2];
                        d_div <= funct3[2];
                    end else if (funct7 == 7'b0 ||
                                 (funct7 == 7'b0100000 &&
                                  (funct3 == 3'b000 || funct3 == 3'b101))) begin
                        d_alu   <= funct3 != 3'b001 && funct3 != 3'b101;
                        d_shift <= funct3 == 3'b001 || funct3 == 3'b101;
                        case (funct3)
                            3'b000:  d_alu_op <= funct7[5] ? `ALU_SUB : `ALU_ADD;
                            3'b010:  d_alu_op <= `ALU_SLT;
                            3'b011:  d_alu_op <= `ALU_SLTU;
                            3'b100:  d_alu_op <= `ALU_XOR;
                            3'b110:  d_alu_op <= `ALU_OR;
                            default: d_alu_op <= `ALU_AND;
                        endcase
                    end else begin
                        d_illegal <= 1'b1;
                    end
                end
                7'b0001111: begin  // FENCE, FENCE.I: no-ops
                    d_illegal <= funct3[2] | funct3[1];
                end
                7'b0101111: begin  // AMO
                    d_size <= 2'b10;
                    if (funct3 != 3'b010) begin
                        d_illegal <= 1'b1;
                    end else begin
                        case (funct5)
                            5'b00010: begin
                                d_lr      <= rs2 == 5'b0;
                                d_illegal <= rs2 != 5'b0;
                            end
                            5'b00011: d_sc <= 1'b1;
                            5'b00000, 5'b00001, 5'b00100, 5'b01000, 5'b01100,
                            5'b10000, 5'b10100, 5'b11000, 5'b11100: d_amo <= 1'b1;
                            default: d_illegal <= 1'b1;
                        endcase
                    end
                    case (funct5)
                        5'b00000: d_alu_op <= `ALU_ADD;
                        5'b00100: d_alu_op <= `ALU_XOR;
                        5'b01000: d_alu_op <= `ALU_OR;
                        5'b01100: d_alu_op <= `ALU_AND;
                        5'b10000: d_alu_op <= `ALU_MIN;
                        5'b10100: d_alu_op <= `ALU_MAX;
                        5'b11000: d_alu_op <= `ALU_MINU;
                        5'b11100: d_alu_op <= `ALU_MAXU;
                        default:  d_alu_op <= `ALU_PASSB;
                    endcase
                end
                7'b1110011: begin  // SYSTEM
                    if (funct3 == 3'b000) begin
                        if (ir[31:25] == 7'b0001001 && rd == 5'b0)
                            d_sfence <= 1'b1;
                        else if (rs1 != 5'b0 || rd != 5'b0)
                            d_illegal <= 1'b1;
                        else begin
                            case (ir[31:20])
                                12'h000: d_ecall  <= 1'b1;
                                12'h001: d_ebreak <= 1'b1;
                                12'h302: d_mret   <= 1'b1;
                                12'h102: d_sret   <= 1'b1;
                                12'h105: d_wfi    <= 1'b1;
                                12'hf02: d_fret   <= 1'b1;
                                default: d_illegal <= 1'b1;
                            endcase
                        end
                    end else if (funct3 == 3'b100) begin
                        d_illegal <= 1'b1;
                    end else begin
                        d_csr <= 1'b1;
                    end
                end
                default: d_illegal <= 1'b1;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Register file and F-RAM
    // ------------------------------------------------------------------
    // The register file is the top 128 words of the F-RAM.  F-RAM accesses
    // only happen in S_ACC and S_AMO_ALU where the register file ports are
    // otherwise idle: reads use port A (rs2 on port B is still needed by an
    // AMO) and writes port B.
    logic        rf_a_en, rf_b_en, rf_b_we, rf_b_alu;
    logic [ 6:0] rf_a_addr, rf_b_addr;
    logic [31:0] rf_a_data, rf_b_data, rf_b_wdata;
    logic        fram_rd, fram_wr;
    logic [ 3:0] fram_we;
    logic [31:0] store_data;

    wire         fram_sel = st[S_ACC] | st[S_AMO_ALU];

    MervRAM #(
        .INIT_FILE(FFW_INIT)
    ) ram (
        .clk    (clk),
        .a_en   (rf_a_en | fram_rd),
        .a_addr (st[S_ACC] ? pa[12:2] : {4'hf, rf_a_addr}),
        .a_data (rf_a_data),
        .b_en   (rf_b_en | fram_wr),
        .b_we   (fram_sel ? fram_we : {4{rf_b_we}}),
        .b_addr (fram_sel ? pa[12:2] : {4'hf, rf_b_addr}),
        .b_wdata(st[S_ACC] ? store_data : rf_b_wdata),
        .b_data (rf_b_data)
    );

    // ------------------------------------------------------------------
    // ALU and its input multiplexers
    // ------------------------------------------------------------------
    logic [`ALU_CTRL_W-1:0] alu_ctrl_q;
    // AMO min/max: whether to keep the old value, from S_AMO_CMP.
    logic        amo_pick_a;
    wire         amo_minmax = d_alu_op == `ALU_MIN || d_alu_op == `ALU_MAX ||
                              d_alu_op == `ALU_MINU || d_alu_op == `ALU_MAXU;
    logic [ 1:0] alu_a_sel, alu_b_sel;
    logic [31:0] alu_a, alu_b, alu_result;
    logic        alu_eq, alu_lt, alu_ltu;

    localparam logic [1:0] A_RS1 = 2'd0, A_PC = 2'd1, A_RESULT = 2'd2,
                           A_ADDR = 2'd3;
    localparam logic [1:0] B_RS2 = 2'd0, B_IMM = 2'd1, B_IR = 2'd2,
                           B_FOUR = 2'd3;

    always_comb begin
        case (alu_a_sel)
            A_RS1:    alu_a = rf_a_data;
            A_PC:     alu_a = pc;
            A_RESULT: alu_a = result;
            default:  alu_a = addr;
        endcase
        case (alu_b_sel)
            B_RS2:   alu_b = rf_b_data;
            B_IMM:   alu_b = imm;
            B_IR:    alu_b = ir;
            default: alu_b = 32'd4;
        endcase
    end

    // The outcome of S_EXEC computed in S_DECODE2 from the decode (the
    // privilege level and mstatus can't change in between): register loads,
    // a trap and its cause, or the next state.
    logic       e_ld_result, e_ld_addr;
    logic       e_trap;
    logic [4:0] e_cause;
    logic [1:0] e_tval;
    logic       e_xret, e_fret, e_csr, e_mul, e_div, e_shift, e_branch;
    logic       e_jump, e_mem, e_wb, e_flush, e_flush_all;

    MervALU alu (
        .ctrl  (alu_ctrl_q),
        .a     (alu_a),
        .b     (alu_b),
        .result(alu_result),
        .eq    (alu_eq),
        .lt    (alu_lt),
        .ltu   (alu_ltu)
    );

    // ------------------------------------------------------------------
    // Multiply/divide
    // ------------------------------------------------------------------
    logic        mul_done, div_done;
    logic [31:0] mul_result, div_result;

    MervMul mul (
        .clk   (clk),
        .start (st[S_EXEC] && d_mul),
        .funct (funct3[1:0]),
        .a     (rf_a_data),
        .b     (rf_b_data),
        .result(mul_result),
        .done  (mul_done)
    );

    // Signed division with a negative operand is emulated in F mode, the
    // hardware divider is unsigned only.
    wire div_emulate = HW_DIV == 0 ||
                       (!funct3[0] && (rf_a_data[31] || rf_b_data[31]));

    generate
        if (HW_DIV != 0) begin : gen_div
            MervDiv div (
                .clk     (clk),
                .reset   (reset),
                .start   (st[S_EXEC] && d_div && !div_emulate),
                .want_rem(funct3[1]),
                .a       (rf_a_data),
                .b       (rf_b_data),
                .result  (div_result),
                .done    (div_done)
            );
        end else begin : gen_no_div
            assign div_result = 32'b0;
            assign div_done   = 1'b0;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Translation
    // ------------------------------------------------------------------
    wire        acc_fetch = acc == `ACC_FETCH;
    wire        acc_load  = acc == `ACC_LOAD || acc == `ACC_LR;
    wire        acc_store = acc == `ACC_STORE || acc == `ACC_SC ||
                            acc == `ACC_AMO;
    wire        acc_read  = acc == `ACC_FETCH || acc == `ACC_LOAD ||
                            acc == `ACC_LR || acc == `ACC_AMO;
    wire [ 1:0] eff_priv  = (!acc_fetch && priv == `PRIV_M && m_mprv) ?
                            m_mpp : priv;
    wire        translate = !is_f && satp_mode && eff_priv != `PRIV_M;
    wire        fetch_translate = !is_f && satp_mode && priv != `PRIV_M;

    logic [31:0] tlb_pa;
    logic        tlb_miss, tlb_fault;
    logic        tlb_flush, tlb_flush_va, tlb_write;

    MervTLB #(
        .ENTRIES(TLB_ENTRIES)
    ) tlb (
        .clk      (clk),
        .reset    (reset),
        .lookup   (st[S_TLB1]),
        .check    (st[S_TLB2]),
        .va       (addr),
        .is_fetch (acc_fetch),
        .is_store (acc_store),
        .eff_user (eff_priv == `PRIV_U),
        .sum      (m_sum),
        .mxr      (m_mxr),
        .pa       (tlb_pa),
        .miss     (tlb_miss),
        .fault    (tlb_fault),
        .flush    (tlb_flush),
        .flush_va (tlb_flush_va),
        .write    (tlb_write),
        .write_idx(ftlbidx),
        .write_hi (ftlbhi),
        .write_lo ({alu_result[31:12], alu_result[3:0]})
    );

    wire cur_miss   = xl_tlb & tlb_miss;
    wire cur_fault  = xl_tlb & tlb_fault;
    wire cur_fram   = is_f && pa[31:13] == 19'b0;
    wire resv_match = resv_valid && resv_addr == pa[31:2];

    // ------------------------------------------------------------------
    // Memory data
    // ------------------------------------------------------------------
    logic [ 3:0] store_strb;

    always_comb begin
        case (size)
            2'b00:   store_data = {4{rf_b_data[7:0]}};
            2'b01:   store_data = {2{rf_b_data[15:0]}};
            default: store_data = rf_b_data;
        endcase
        case (size)
            2'b00:   store_strb = 4'b0001 << pa[1:0];
            2'b01:   store_strb = pa[1] ? 4'b1100 : 4'b0011;
            default: store_strb = 4'b1111;
        endcase
    end

    wire [31:0] rdata_raw = st[S_FR2] ? rf_a_data : axi_rdata;
    wire        rdata_err = st[S_R] && axi_rresp[1];

    // ------------------------------------------------------------------
    // Interrupts
    // ------------------------------------------------------------------
    wire [5:0] mip_bits = {meip, seip | seip_sw, mtip, stip, msip, ssip};
    wire [5:0] pending  = mip_bits & mie_r;
    wire [5:0] deleg6   = {1'b0, mideleg[2], 1'b0, mideleg[1], 1'b0, mideleg[0]};
    wire       m_ints_en = priv != `PRIV_M || m_mie;
    wire       s_ints_en = priv == `PRIV_U || (priv == `PRIV_S && m_sie);
    wire [5:0] enabled  = (m_ints_en ? (pending & ~deleg6) : 6'b0) |
                          (s_ints_en ? (pending & deleg6) : 6'b0);
    logic [4:0] irq_cause;

    // Interrupts and counter wrap events are sampled during S_FETCH (after
    // any state change by the previous instruction has taken effect) and
    // taken in the following state, keeping them off the next state path.
    logic       irq_q, wrap_q;
    logic [2:0] wrap_cause_q;
    logic [4:0] irq_cause_q;

    always_ff @(posedge clk) begin
        irq_q       <= !is_f && |enabled;
        irq_cause_q <= irq_cause;
        // An sfence.vma event comes first so that the firmware can
        // invalidate its second level TLB before anything is translated.
        wrap_q       <= !is_f && (f_sfpend || f_cywrap || f_irwrap);
        wrap_cause_q <= f_sfpend ? `FEV_SFENCE : f_cywrap ? `FEV_CYWRAP :
                                                            `FEV_IRWRAP;
    end

    // The first state of an instruction fetch after S_FETCH.
    wire fetch_first = acc_fetch && (st[S_TLB1] || (st[S_ACC] && !xl_tlb));

    always_comb begin
        // MEI, MSI, MTI, SEI, SSI, STI
        if (enabled[5]) irq_cause = 5'd11;
        else if (enabled[1]) irq_cause = 5'd3;
        else if (enabled[3]) irq_cause = 5'd7;
        else if (enabled[4]) irq_cause = 5'd9;
        else if (enabled[0]) irq_cause = 5'd1;
        else irq_cause = 5'd5;
    end

    // ------------------------------------------------------------------
    // CSR address decode
    // ------------------------------------------------------------------
    // Flop CSRs are identified by a small index so that the read multiplexer
    // and write enables decode only a few bits.
    localparam logic [4:0]
        C_NONE = 5'd0, C_MSTATUS = 5'd1, C_SSTATUS = 5'd2, C_MEDELEG = 5'd3,
        C_MIDELEG = 5'd4, C_MIE = 5'd5, C_SIE = 5'd6, C_MIP = 5'd7,
        C_SIP = 5'd8, C_MCOUNTEREN = 5'd9, C_SCOUNTEREN = 5'd10,
        C_MCYCLE = 5'd11, C_MINSTRET = 5'd12, C_FSTATUS = 5'd13,
        C_FCAUSE = 5'd14, C_FINJECT = 5'd15, C_FTLBIDX = 5'd16,
        C_FTLBHI = 5'd17, C_FTLBLO = 5'd18, C_FBOOTVEC = 5'd19,
        C_FCONFIG = 5'd20, C_BRAM = 5'd21;

    wire [11:0] csr_addr  = ir[31:20];
    wire        csr_write = funct3[1:0] == 2'b01 || rs1 != 5'b0;

    logic [ 4:0] sel, c_sel;
    logic [ 6:0] bram_idx, c_bram_idx;
    logic [ 1:0] wmask, c_wmask;  // [0]: clear bits 1:0, [1]: satp ASID
    logic        c_illegal, c_emulate;
    logic        known, ro_violation, priv_violation;
    logic [31:0] c_ff_rdata;

    always_comb begin
        sel      = C_NONE;
        bram_idx = 7'b0;
        wmask    = 2'b00;
        known    = 1'b1;

        case (csr_addr)
            12'h340: begin sel = C_BRAM; bram_idx = `RF_MSCRATCH; end
            12'h341: begin sel = C_BRAM; bram_idx = `RF_MEPC; wmask = 2'b01; end
            12'h342: begin sel = C_BRAM; bram_idx = `RF_MCAUSE; end
            12'h343: begin sel = C_BRAM; bram_idx = `RF_MTVAL; end
            12'h305: begin sel = C_BRAM; bram_idx = `RF_MTVEC; wmask = 2'b01; end
            12'h140: begin sel = C_BRAM; bram_idx = `RF_SSCRATCH; end
            12'h141: begin sel = C_BRAM; bram_idx = `RF_SEPC; wmask = 2'b01; end
            12'h142: begin sel = C_BRAM; bram_idx = `RF_SCAUSE; end
            12'h143: begin sel = C_BRAM; bram_idx = `RF_STVAL; end
            12'h105: begin sel = C_BRAM; bram_idx = `RF_STVEC; wmask = 2'b01; end
            12'h180: begin sel = C_BRAM; bram_idx = `RF_SATP; wmask = 2'b10; end
            12'h7c1: begin sel = C_BRAM; bram_idx = `RF_FEPC; wmask = 2'b01; end
            12'h7c3: begin sel = C_BRAM; bram_idx = `RF_FTVAL; end
            12'h7c4: begin sel = C_BRAM; bram_idx = `RF_FPADDR; end
            12'h300: sel = C_MSTATUS;
            12'h100: sel = C_SSTATUS;
            12'h302: sel = C_MEDELEG;
            12'h303: sel = C_MIDELEG;
            12'h304: sel = C_MIE;
            12'h104: sel = C_SIE;
            12'h344: sel = C_MIP;
            12'h144: sel = C_SIP;
            12'h306: sel = C_MCOUNTEREN;
            12'h106: sel = C_SCOUNTEREN;
            12'hb00, 12'hc00: sel = C_MCYCLE;
            12'hb02, 12'hc02: sel = C_MINSTRET;
            12'h7c0: sel = C_FSTATUS;
            12'h7c2: sel = C_FCAUSE;
            12'h7c5: sel = C_FINJECT;
            12'h7c8: sel = C_FTLBIDX;
            12'h7c9: sel = C_FTLBHI;
            12'h7ca: sel = C_FTLBLO;
            12'h7cb: sel = C_FBOOTVEC;
            12'h7cc: sel = C_FCONFIG;
            default: known = 1'b0;
        endcase
    end

    always_comb begin
        logic is_fcsr;
        is_fcsr = csr_addr[11:4] == 8'h7c && csr_addr[3:0] <= 4'hc;
        ro_violation = csr_write && (csr_addr[11:10] == 2'b11 ||
                                     csr_addr == 12'h7cb || csr_addr == 12'h7cc);
        priv_violation = 1'b0;
        if (is_fcsr) begin
            priv_violation = !is_f;
        end else if (!is_f) begin
            if (csr_addr[9:8] > priv) priv_violation = 1'b1;
            if (csr_addr == 12'h180 && priv == `PRIV_S && m_tvm)
                priv_violation = 1'b1;
            if (csr_addr == 12'hc00 || csr_addr == 12'hc02) begin
                if (priv != `PRIV_M && !mcounteren[csr_addr[1:0]])
                    priv_violation = 1'b1;
                if (priv == `PRIV_U && !scounteren[csr_addr[1:0]])
                    priv_violation = 1'b1;
            end
        end
    end

    wire [31:0] mstatus_val = {9'b0, m_tsr, m_tw, m_tvm, m_mxr, m_sum, m_mprv,
                               4'b0, m_mpp, 2'b0, m_spp, m_mpie, 1'b0, m_spie,
                               1'b0, m_mie, 1'b0, m_sie, 1'b0};
    wire [31:0] mie_val     = {20'b0, mie_r[5], 1'b0, mie_r[4], 1'b0, mie_r[3],
                               1'b0, mie_r[2], 1'b0, mie_r[1], 1'b0, mie_r[0],
                               1'b0};
    wire [31:0] mip_val     = {20'b0, mip_bits[5], 1'b0, mip_bits[4], 1'b0,
                               mip_bits[3], 1'b0, mip_bits[2], 1'b0,
                               mip_bits[1], 1'b0, mip_bits[0], 1'b0};
    wire [31:0] mideleg_val = {22'b0, mideleg[2], 3'b0, mideleg[1], 3'b0,
                               mideleg[0], 1'b0};

    always_ff @(posedge clk) begin
        if (st[S_CSR1]) begin
            c_sel      <= sel;
            c_bram_idx <= bram_idx;
            c_wmask    <= wmask;
            c_illegal  <= known ? (priv_violation | ro_violation) : is_f;
            c_emulate  <= !known && !is_f;
        end
        if (st[S_CSR2]) begin
            case (c_sel)
                C_MSTATUS:    c_ff_rdata <= mstatus_val;
                C_SSTATUS:    c_ff_rdata <= mstatus_val & 32'h000c0122;
                C_MEDELEG:    c_ff_rdata <= {16'b0, medeleg};
                C_MIDELEG:    c_ff_rdata <= mideleg_val;
                C_MIE:        c_ff_rdata <= mie_val;
                C_SIE:        c_ff_rdata <= mie_val & mideleg_val;
                // A CSR instruction that writes mip reads (and so writes
                // back) only the software SEIP bit, not the external
                // interrupt, as the privileged spec requires.
                C_MIP:        c_ff_rdata <= csr_write ?
                                  (mip_val & ~32'h200) | {22'b0, seip_sw, 9'b0} :
                                  mip_val;
                C_SIP:        c_ff_rdata <= mip_val & mideleg_val;
                C_MCOUNTEREN: c_ff_rdata <= {29'b0, mcounteren};
                C_SCOUNTEREN: c_ff_rdata <= {29'b0, scounteren};
                C_MCYCLE:     c_ff_rdata <= mcycle;
                C_MINSTRET:   c_ff_rdata <= minstret;
                C_FSTATUS:    c_ff_rdata <= {21'b0, f_sfpend, f_irwrap, f_cywrap, 5'b0,
                                             f_berr, f_pprv};
                C_FCAUSE:     c_ff_rdata <= {29'b0, f_cause};
                C_FINJECT:    c_ff_rdata <= {finj_valid, 26'b0, finj_cause};
                C_FTLBIDX:    c_ff_rdata <= {28'b0, ftlbidx};
                C_FBOOTVEC:   c_ff_rdata <= reset_vector;
                C_FCONFIG:    c_ff_rdata <= {21'b0, BARREL_SHIFT != 0, HW_DIV != 0,
                                             NATIVE_AMO != 0, 8'(TLB_ENTRIES)};
                default:      c_ff_rdata <= 32'b0;
            endcase
        end
    end

    wire c_from_bram = c_sel == C_BRAM;
    wire csr_ff_write = st[S_CSR5] && csr_write && !c_from_bram;

    // ------------------------------------------------------------------
    // Trap delegation
    // ------------------------------------------------------------------
    wire trap_to_s = priv != `PRIV_M &&
                     (trap_intr ? (trap_cause == 5'd1 ? mideleg[0] :
                                   trap_cause == 5'd5 ? mideleg[1] :
                                   trap_cause == 5'd9 ? mideleg[2] : 1'b0)
                                : medeleg[trap_cause[3:0]] && !trap_cause[4]);
    logic trap_to_s_q;

    // ------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------
    // A trap/F event request from any state, with the source of its
    // (f)tval.
    logic        raise_trap, raise_fev;
    logic [ 4:0] raise_cause;
    logic        raise_intr;
    logic [ 2:0] raise_fcause;
    logic [ 1:0] raise_tval;
    logic        retire;

    // Register loads from the ALU.
    logic        ld_pc, ld_addr, ld_pa, ld_result, ld_wdata;

    always_comb begin
        ld_pc     = 1'b0;
        ld_addr   = 1'b0;
        ld_pa     = 1'b0;
        ld_result = 1'b0;
        ld_wdata  = 1'b0;

        unique case (1'b1)
            // A pending sfence.vma event keeps its address in addr for ftval.
            st[S_FETCH]: begin
                ld_addr = !(f_sfpend && !is_f);
                ld_pa   = 1'b1;
            end
            st[S_EXEC]: begin
                ld_result = e_ld_result;
                ld_addr   = e_ld_addr;
                ld_pa     = e_ld_addr;
            end
            // The PC is only updated if a branch is taken or a jump target is
            // aligned, otherwise it is the epc and the target is the tval.
            st[S_BRANCH]: begin
                ld_pc   = taken && !imm[1];
                ld_addr = 1'b1;
            end
            st[S_JUMP]: begin
                ld_pc   = !jump_misaligned;
                ld_addr = 1'b1;
            end
            st[S_WB]: ld_pc = !pc_done;
            st[S_SHIFT]: ld_result = shamt_zero && shift_rev;
            st[S_CSR4]: ld_result = c_from_bram;
            st[S_AMO_ALU]: ld_wdata = 1'b1;
            st[S_TRAP4], st[S_XRET3], st[S_FRET3]: ld_pc = 1'b1;
            st[S_FRET4]: ld_addr = 1'b1;
            default: ;
        endcase
    end

    // The ALU control is registered, computed from the next state so that
    // the operand multiplexers are driven straight from flops.
    logic [3:0] n_alu_op;
    logic [1:0] n_a_sel, n_b_sel;
    logic [3:0] exec_alu_op;
    logic [1:0] exec_a_sel, exec_b_sel;

    // Control for S_EXEC from the registered decode.
    always_comb begin
        exec_alu_op = `ALU_ADD;
        exec_a_sel  = A_RS1;
        exec_b_sel  = B_IMM;
        if (d_sfence) begin
            // addr = rs1 | rs1 number (imm_z): non-zero for an address.
            exec_alu_op = `ALU_OR;
        end else if (d_jal | d_jalr) begin
            // rd = pc + 4
            exec_a_sel = A_PC;
            exec_b_sel = B_FOUR;
        end else if (d_branch) begin
            exec_alu_op = `ALU_SUB;
            exec_b_sel  = B_RS2;
        end else if (d_alu) begin
            exec_alu_op = d_alu_op;
            exec_a_sel  = d_a_pc ? A_PC : A_RS1;
            exec_b_sel  = d_b_imm ? B_IMM : B_RS2;
        end else if (d_shift) begin
            // Left shifts are right shifts of the bit reversed value.
            exec_alu_op = funct3 == 3'b001 ? `ALU_REVA : `ALU_PASSA;
        end else if (d_csr) begin
            // Stage the source operand in the BRAM scratch word.
            exec_alu_op = funct3[2] ? `ALU_PASSB : `ALU_PASSA;
        end
    end

    always_comb begin
        n_alu_op = `ALU_ADD;
        n_a_sel  = A_PC;
        n_b_sel  = B_FOUR;

        unique case (1'b1)
            nst_n[S_FETCH], nst_n[S_TRAP1], nst_n[S_FENT1]: n_alu_op = `ALU_PASSA;
            nst_n[S_EXEC]: begin
                n_alu_op = exec_alu_op;
                n_a_sel  = exec_a_sel;
                n_b_sel  = exec_b_sel;
            end
            nst_n[S_BRANCH]: n_b_sel = B_IMM;
            nst_n[S_JUMP]: begin
                n_a_sel = d_jalr ? A_RS1 : A_PC;
                n_b_sel = B_IMM;
            end
            nst_n[S_AMO_CMP]: begin
                n_alu_op = `ALU_SUB;
                n_a_sel  = A_RESULT;
                n_b_sel  = B_RS2;
            end
            nst_n[S_AMO_ALU]: begin
                // Min/max pick the old value (a) or rs2 (b) from the
                // comparison performed in S_AMO_CMP.
                if (amo_minmax)
                    n_alu_op = amo_pick_a ? `ALU_PASSA : `ALU_PASSB;
                else
                    n_alu_op = d_alu_op;
                n_a_sel  = A_RESULT;
                n_b_sel  = B_RS2;
            end
            nst_n[S_SHIFT]: begin
                n_alu_op = `ALU_REVA;
                n_a_sel  = A_RESULT;
            end
            nst_n[S_CSR4]: begin
                n_alu_op = `ALU_PASSA;
                n_a_sel  = A_RS1;
            end
            nst_n[S_CSR5]: begin
                // New value from the old value (result) and the source
                // operand (read back from the scratch word on port B).
                n_alu_op = funct3[1:0] == 2'b01 ? `ALU_PASSB :
                           funct3[1:0] == 2'b10 ? `ALU_OR : `ALU_ANDN;
                n_a_sel  = A_RESULT;
                n_b_sel  = B_RS2;
            end
            nst_n[S_TRAP2]: begin                     // cause
                n_alu_op = `ALU_PASSB;
                n_b_sel  = B_IMM;
            end
            nst_n[S_TRAP3], nst_n[S_FENT2]: begin       // tval
                case (tval_src)
                    TV_ADDR: begin
                        n_alu_op = `ALU_PASSA;
                        n_a_sel  = A_ADDR;
                    end
                    TV_IR: begin
                        n_alu_op = `ALU_PASSB;
                        n_b_sel  = B_IR;
                    end
                    TV_PC:   n_alu_op = `ALU_PASSA;
                    default: n_alu_op = `ALU_ZERO;
                endcase
            end
            nst_n[S_FENT3]: begin                     // fpaddr
                n_alu_op = `ALU_PASSA;
                n_a_sel  = A_ADDR;
            end
            nst_n[S_TRAP4], nst_n[S_XRET3], nst_n[S_FRET3], nst_n[S_FRET4]: begin
                n_alu_op = `ALU_PASSA;
                n_a_sel  = A_RS1;
            end
            default: ;
        endcase
    end

    function automatic logic [`ALU_CTRL_W-1:0] alu_ctrl(input logic [3:0] op);
        logic [`ALU_CTRL_W-1:0] c;
        c = '0;
        case (op)
            `ALU_ADD:   c[`ALU_C_SUM] = 1'b1;
            `ALU_SUB:   begin c[`ALU_C_SUM] = 1'b1; c[`ALU_C_SUB] = 1'b1; end
            `ALU_SLT:   begin c[`ALU_C_SET] = 1'b1; c[`ALU_C_SUB] = 1'b1; end
            `ALU_SLTU:  begin
                c[`ALU_C_SET]  = 1'b1;
                c[`ALU_C_SETU] = 1'b1;
                c[`ALU_C_SUB]  = 1'b1;
            end
            `ALU_XOR:   c[`ALU_C_LOP+:3] = `LOP_XOR;
            `ALU_OR:    c[`ALU_C_LOP+:3] = `LOP_OR;
            `ALU_AND:   c[`ALU_C_LOP+:3] = `LOP_AND;
            `ALU_ANDN:  c[`ALU_C_LOP+:3] = `LOP_ANDN;
            `ALU_PASSA: c[`ALU_C_LOP+:3] = `LOP_PASSA;
            `ALU_PASSB: c[`ALU_C_LOP+:3] = `LOP_PASSB;
            `ALU_REVA:  c[`ALU_C_LOP+:3] = `LOP_REVA;
            default:    c[`ALU_C_LOP+:3] = `LOP_ZERO;
        endcase
        alu_ctrl = c;
    endfunction

    always_ff @(posedge clk) begin
        alu_ctrl_q <= alu_ctrl(n_alu_op);
        alu_a_sel  <= n_a_sel;
        alu_b_sel  <= n_b_sel;
        // Reset enters S_FETCH.
        if (reset) begin
            alu_ctrl_q <= alu_ctrl(`ALU_PASSA);
            alu_a_sel  <= A_PC;
        end
    end

    // Register file port control.
    always_comb begin
        rf_a_en   = 1'b0;
        rf_a_addr = {1'b0, is_f, rs1};
        rf_b_en   = 1'b0;
        rf_b_we   = 1'b0;
        rf_b_addr = {1'b0, is_f, rs2};
        rf_b_alu  = 1'b1;

        unique case (1'b1)
            st[S_DECODE]: begin
                rf_a_en = 1'b1;
                rf_b_en = 1'b1;
            end
            st[S_WB]: begin
                rf_b_en   = wb_we;
                rf_b_we   = wb_we;
                rf_b_addr = {1'b0, is_f, rd};
                rf_b_alu  = 1'b0;
            end
            st[S_EXEC]: begin
                rf_b_en   = d_csr;
                rf_b_we   = d_csr;
                rf_b_addr = `RF_SCRATCH;
            end
            st[S_CSR2]: begin
                rf_a_en   = c_from_bram;
                rf_a_addr = c_bram_idx;
                rf_b_en   = 1'b1;
                rf_b_addr = `RF_SCRATCH;
            end
            st[S_CSR5]: begin
                rf_b_en   = csr_write && c_from_bram;
                rf_b_we   = rf_b_en;
                rf_b_addr = c_bram_idx;
            end
            st[S_TRAP1]: begin
                rf_a_en   = 1'b1;
                rf_a_addr = trap_to_s ? `RF_STVEC : `RF_MTVEC;
                rf_b_en   = 1'b1;
                rf_b_we   = 1'b1;
                rf_b_addr = trap_to_s ? `RF_SEPC : `RF_MEPC;
            end
            st[S_TRAP2]: begin
                rf_b_en   = 1'b1;
                rf_b_we   = 1'b1;
                rf_b_addr = trap_to_s_q ? `RF_SCAUSE : `RF_MCAUSE;
            end
            st[S_TRAP3]: begin
                rf_b_en   = 1'b1;
                rf_b_we   = 1'b1;
                rf_b_addr = trap_to_s_q ? `RF_STVAL : `RF_MTVAL;
            end
            st[S_FENT1]: begin
                rf_b_en   = 1'b1;
                rf_b_we   = 1'b1;
                rf_b_addr = `RF_FEPC;
            end
            st[S_FENT2]: begin
                rf_b_en   = 1'b1;
                rf_b_we   = 1'b1;
                rf_b_addr = `RF_FTVAL;
            end
            st[S_FENT3]: begin
                rf_b_en   = 1'b1;
                rf_b_we   = 1'b1;
                rf_b_addr = `RF_FPADDR;
            end
            st[S_XRET1]: begin
                rf_a_en   = 1'b1;
                rf_a_addr = d_mret ? `RF_MEPC : `RF_SEPC;
            end
            st[S_FRET1]: begin
                rf_a_en   = 1'b1;
                rf_a_addr = `RF_FEPC;
            end
            st[S_FRET2]: begin
                rf_a_en   = 1'b1;
                rf_a_addr = `RF_FTVAL;
            end
            default: ;
        endcase
    end

    // BRAM write data: GPR write back from result, everything else (CSRs,
    // trap state) from the ALU with the CSR write masks applied.
    always_comb begin
        rf_b_wdata = rf_b_alu ? alu_result : result;
        if (st[S_CSR5] && c_wmask[0]) rf_b_wdata[1:0] = 2'b00;
        if (st[S_CSR5] && c_wmask[1]) rf_b_wdata[30:22] = 9'b0;
    end

    always_comb begin
        nst          = '0;
        raise_trap   = 1'b0;
        raise_fev    = 1'b0;
        raise_cause  = 5'b0;
        raise_intr   = 1'b0;
        raise_fcause = 3'b0;
        raise_tval   = TV_ADDR;
        retire       = 1'b0;
        fram_rd      = 1'b0;
        fram_wr      = 1'b0;
        fram_we      = 4'b0;
        tlb_flush    = 1'b0;
        tlb_flush_va = 1'b0;
        tlb_write    = 1'b0;

        unique case (1'b1)
            st[S_FETCH]: begin
                nst[S_TLB1] = fetch_translate;
                nst[S_ACC]  = !fetch_translate;
            end
            st[S_TLB1]: nst[S_TLB2] = 1'b1;
            st[S_TLB2]: nst[S_ACC] = 1'b1;
            st[S_XLATE]: begin
                if ((size == 2'b10 && addr[1:0] != 2'b00) ||
                    (size == 2'b01 && addr[0])) begin
                    raise_trap  = 1'b1;
                    raise_cause = acc_load ? `EXC_LOAD_MISALIGNED :
                                             `EXC_STORE_MISALIGNED;
                end else begin
                    begin nst[S_TLB1] = translate; nst[S_ACC] = !(translate); end
                end
            end
            st[S_ACC]: begin
                if (cur_miss) begin
                    raise_fev    = 1'b1;
                    raise_fcause = acc_fetch ? `FEV_ITLB :
                                   acc_load ? `FEV_LTLB : `FEV_STLB;
                end else if (cur_fault) begin
                    raise_trap  = 1'b1;
                    raise_cause = acc_fetch ? `EXC_INSN_PAGE :
                                  acc_load ? `EXC_LOAD_PAGE : `EXC_STORE_PAGE;
                end else if (acc == `ACC_SC && !resv_match) begin
                    nst[S_WB] = 1'b1;
                end else if (acc == `ACC_AMO && NATIVE_AMO == 0) begin
                    raise_fev    = 1'b1;
                    raise_fcause = `FEV_EMULATE;
                    raise_tval   = TV_IR;
                end else if (acc_read) begin
                    fram_rd    = cur_fram;
                    begin nst[S_FR1] = cur_fram; nst[S_AR] = !(cur_fram); end
                end else begin
                    fram_wr    = cur_fram;
                    fram_we    = cur_fram ? store_strb : 4'b0;
                    begin nst[S_WB] = cur_fram; nst[S_AW] = !cur_fram; end
                end
            end
            st[S_AR]: begin
                nst[S_R]  = axi_arready;
                nst[S_AR] = !axi_arready;
            end
            st[S_FR1]: nst[S_FR2] = 1'b1;
            st[S_R], st[S_FR2]: begin
                nst[S_R] = st[S_R] && !axi_rvalid;
                if (st[S_FR2] || axi_rvalid) begin
                    if (rdata_err && !is_f) begin
                        raise_trap  = 1'b1;
                        raise_cause = acc_fetch ? `EXC_INSN_ACCESS :
                                      acc == `ACC_AMO ? `EXC_STORE_ACCESS :
                                      `EXC_LOAD_ACCESS;
                    end else if (rdata_err && acc_fetch) begin
                        nst[S_HALT] = 1'b1;
                    end else if (acc_fetch) begin
                        nst[S_DECODE] = 1'b1;
                    end else if (acc == `ACC_AMO) begin
                        // Min/max compare first, the other AMOs go straight
                        // to the ALU.
                        nst[S_AMO_CMP] = amo_minmax;
                        nst[S_AMO_ALU] = !amo_minmax;
                    end else if (acc == `ACC_LOAD && size != 2'b10) begin
                        nst[S_SHIFT] = 1'b1;
                    end else begin
                        nst[S_WB] = 1'b1;
                    end
                end
            end
            st[S_AMO_CMP]: nst[S_AMO_PICK] = 1'b1;
            st[S_AMO_PICK]: nst[S_AMO_ALU] = 1'b1;
            st[S_AMO_ALU]: begin
                fram_wr    = cur_fram;
                fram_we    = cur_fram ? 4'b1111 : 4'b0;
                begin nst[S_WB] = cur_fram; nst[S_AW] = !cur_fram; end
            end
            st[S_AW]: begin
                nst[S_B]  = (aw_done || axi_awready) && (w_done || axi_wready);
                nst[S_AW] = !nst[S_B];
            end
            st[S_B]: begin
                nst[S_B] = !axi_bvalid;
                if (axi_bvalid) begin
                    if (axi_bresp[1] && !is_f) begin
                        raise_trap  = 1'b1;
                        raise_cause = `EXC_STORE_ACCESS;
                    end else begin
                        nst[S_WB] = 1'b1;
                    end
                end
            end
            st[S_DECODE]: nst[S_DECODE2] = 1'b1;
            st[S_DECODE2]: nst[S_EXEC] = 1'b1;
            st[S_EXEC]: begin
                if (e_trap) begin
                    raise_trap  = 1'b1;
                    raise_cause = e_cause;
                    raise_tval  = e_tval;
                end else if (e_div && div_emulate) begin
                    raise_fev    = 1'b1;
                    raise_fcause = `FEV_EMULATE;
                    raise_tval   = TV_IR;
                end
                nst[S_XRET1]  = e_xret;
                nst[S_FRET1]  = e_fret;
                nst[S_CSR1]   = e_csr;
                nst[S_MUL]    = e_mul;
                nst[S_DIV]    = e_div && !div_emulate;
                nst[S_SHIFT]  = e_shift;
                nst[S_BRANCH] = e_branch;
                nst[S_JUMP]   = e_jump;
                nst[S_XLATE]  = e_mem;
                nst[S_WB]     = e_wb;
            end
            st[S_BRANCH]: begin
                if (taken && imm[1]) begin
                    raise_trap  = 1'b1;
                    raise_cause = `EXC_INSN_MISALIGNED;
                end else begin
                    nst[S_WB] = 1'b1;
                end
            end
            st[S_JUMP]: begin
                if (jump_misaligned) begin
                    raise_trap  = 1'b1;
                    raise_cause = `EXC_INSN_MISALIGNED;
                end else begin
                    nst[S_WB] = 1'b1;
                end
            end
            st[S_SHIFT]: begin
                nst[S_LDEXT] = shamt_zero && shift_ld;
                nst[S_WB]    = shamt_zero && !shift_ld;
                nst[S_SHIFT] = !shamt_zero;
            end
            st[S_LDEXT]: nst[S_WB] = 1'b1;
            st[S_MUL]: begin
                nst[S_WB]  = mul_done;
                nst[S_MUL] = !mul_done;
            end
            st[S_DIV]: begin
                nst[S_WB]  = div_done;
                nst[S_DIV] = !div_done;
            end
            st[S_WB]: begin
                retire       = 1'b1;
                tlb_flush    = e_flush && e_flush_all;
                tlb_flush_va = e_flush && !e_flush_all;
                nst[S_FETCH] = 1'b1;
            end
            st[S_CSR1]: nst[S_CSR2] = 1'b1;
            st[S_CSR2]: begin
                if (c_illegal) begin
                    raise_trap  = 1'b1;
                    raise_cause = `EXC_ILLEGAL;
                    raise_tval  = TV_IR;
                end else if (c_emulate) begin
                    raise_fev    = 1'b1;
                    raise_fcause = `FEV_EMULATE;
                    raise_tval   = TV_IR;
                end else begin
                    nst[S_CSR3] = 1'b1;
                end
            end
            st[S_CSR3]: nst[S_CSR4] = 1'b1;
            st[S_CSR4]: nst[S_CSR5] = 1'b1;
            st[S_CSR5]: begin
                tlb_write  = csr_write && c_sel == C_FTLBLO;
                nst[S_WB] = 1'b1;
            end
            st[S_TRAP0]: nst[S_TRAP1] = 1'b1;
            st[S_FENT0]: nst[S_FENT1] = 1'b1;
            st[S_TRAP1]: nst[S_TRAP2] = 1'b1;
            st[S_TRAP2]: nst[S_TRAP3] = 1'b1;
            st[S_TRAP3]: nst[S_TRAP4] = 1'b1;
            st[S_TRAP4]: nst[S_FETCH] = 1'b1;
            st[S_FENT1]: nst[S_FENT2] = 1'b1;
            st[S_FENT2]: nst[S_FENT3] = 1'b1;
            st[S_FENT3]: nst[S_FETCH] = 1'b1;
            st[S_XRET1]: nst[S_XRET2] = 1'b1;
            st[S_XRET2]: nst[S_XRET3] = 1'b1;
            st[S_XRET3]: begin
                retire     = 1'b1;
                nst[S_FETCH] = 1'b1;
            end
            st[S_FRET1]: nst[S_FRET2] = 1'b1;
            st[S_FRET2]: nst[S_FRET3] = 1'b1;
            st[S_FRET3]: nst[S_FRET4] = 1'b1;
            st[S_FRET4]: begin
                retire     = !finj_valid;
                begin nst[S_TRAP1] = finj_valid; nst[S_FETCH] = !(finj_valid); end
            end
            st[S_HALT]: nst[S_HALT] = 1'b1;
            default: ;
        endcase

        if (fetch_first && wrap_q) begin
            raise_fev    = 1'b1;
            raise_fcause = wrap_cause_q;
            raise_tval   = wrap_cause_q == `FEV_SFENCE ? TV_ADDR : TV_ZERO;
        end else if (fetch_first && irq_q) begin
            raise_trap   = 1'b1;
            raise_fev    = 1'b0;
            raise_intr   = 1'b1;
            raise_cause  = irq_cause_q;
            raise_tval   = TV_ZERO;
        end

        // A trap or F mode event replaces the normal transition, F mode
        // cannot take exceptions or events.
        nst_n = nst;
        if (raise_trap || raise_fev) begin
            nst          = '0;
            nst[S_HALT]  = is_f;
            nst[S_TRAP0] = !is_f && raise_trap;
            nst[S_FENT0] = !is_f && !raise_trap;
        end
    end

    // ------------------------------------------------------------------
    // Sequential datapath
    // ------------------------------------------------------------------
    // The registers loaded from the ALU give it priority over their other
    // sources so that the ALU output passes through a single LUT.
    logic        res_other_en;
    logic [31:0] res_other;

    always_comb begin
        res_other_en = 1'b0;
        res_other    = rdata_raw;
        unique case (1'b1)
            st[S_ACC]: begin
                res_other_en = acc == `ACC_SC;
                res_other    = {31'b0, ~resv_match};
            end
            st[S_R], st[S_FR2]: begin
                res_other_en = (st[S_FR2] || axi_rvalid) && !acc_fetch &&
                               !rdata_err;
            end
            // Right shift by 8 or 1 per cycle.
            st[S_SHIFT]: begin
                res_other_en = !shamt_zero;
                if (BARREL_SHIFT != 0)
                    res_other = 32'($signed({shift_fill, result}) >>> shamt);
                else
                    res_other = shamt[4:3] != 2'b00 ?
                                {{8{shift_fill}}, result[31:8]} :
                                {shift_fill, result[31:1]};
            end
            st[S_LDEXT]: begin
                res_other_en = 1'b1;
                res_other    = size == 2'b00 ?
                               {{24{~d_ld_unsigned & result[7]}}, result[7:0]} :
                               {{16{~d_ld_unsigned & result[15]}}, result[15:0]};
            end
            st[S_MUL]: begin
                res_other_en = 1'b1;
                res_other    = mul_result;
            end
            st[S_DIV]: begin
                res_other_en = 1'b1;
                res_other    = div_result;
            end
            st[S_CSR4]: begin
                res_other_en = !c_from_bram;
                res_other    = c_ff_rdata;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (ld_result) result <= alu_result;
        else if (res_other_en) result <= res_other;

        if (ld_pc) pc <= {alu_result[31:2], 2'b00};
        // F mode entry: TLB misses at 0x4, reset and other events at 0x0.
        else if (st[S_FENT3])
            pc <= {29'b0, fev_cause != `FEV_RESET && !fev_cause[2], 2'b00};
        if (reset) pc <= 32'b0;

        // JALR clears bit 0 of the target (the tval if misaligned).  The
        // physical address of an emulated AMO is staged in addr for fpaddr,
        // its ftval is the instruction.
        if (ld_addr) addr <= {alu_result[31:1], alu_result[0] & ~st[S_JUMP]};
        else if (st[S_ACC] && acc == `ACC_AMO && NATIVE_AMO == 0 && !cur_miss &&
                 !cur_fault)
            addr <= pa;

        if (ld_pa) pa <= alu_result;
        else if (st[S_TLB2]) pa <= tlb_pa;

        if (ld_wdata) wdata <= alu_result;
        else if (st[S_ACC]) wdata <= store_data;
    end

    always_ff @(posedge clk) begin
        st <= nst;

        unique case (1'b1)
            st[S_FETCH]: begin
                acc     <= `ACC_FETCH;
                size    <= 2'b10;
                xl_tlb  <= fetch_translate;
                pc_done <= 1'b0;
                wb_we   <= 1'b0;
            end
            st[S_XLATE]: xl_tlb <= translate;
            st[S_ACC]: begin
                wstrb   <= store_strb;
                aw_done <= 1'b0;
                w_done  <= 1'b0;
                if (acc == `ACC_SC) resv_valid <= 1'b0;
            end
            st[S_AMO_ALU]: begin
                aw_done <= 1'b0;
                w_done  <= 1'b0;
            end
            st[S_AW]: begin
                if (axi_awready) aw_done <= 1'b1;
                if (axi_wready) w_done <= 1'b1;
            end
            st[S_R], st[S_FR2]: begin
                if (st[S_FR2] || axi_rvalid) begin
                    if (acc_fetch) begin
                        ir <= rdata_raw;
                    end else if (!rdata_err && acc == `ACC_LR) begin
                        resv_valid <= 1'b1;
                        resv_addr  <= pa[31:2];
                    end
                    // Sub-word loads are aligned by the shifter.
                    shamt      <= {pa[1:0], 3'b000};
                    shamt_zero <= pa[1:0] == 2'b00;
                    shift_fill <= 1'b0;
                    shift_rev  <= 1'b0;
                    shift_ld   <= 1'b1;
                end
            end
            st[S_DECODE2]: begin
                logic illegal, trap;
                illegal = d_illegal ||
                          (d_mret && (is_f || priv != `PRIV_M)) ||
                          (d_sret && (is_f || priv == `PRIV_U ||
                                      (priv == `PRIV_S && m_tsr))) ||
                          (d_wfi && !is_f && (priv == `PRIV_U ||
                                              (priv == `PRIV_S && m_tw))) ||
                          (d_sfence && !is_f && (priv == `PRIV_U ||
                                                 (priv == `PRIV_S && m_tvm))) ||
                          (d_fret && !is_f);
                trap = illegal || d_ecall || d_ebreak;

                e_ld_result <= d_jal || d_jalr || d_alu || d_shift;
                e_ld_addr   <= d_load || d_store || d_amo || d_lr || d_sc ||
                               d_sfence;
                e_trap      <= trap;
                e_cause     <= illegal ? `EXC_ILLEGAL :
                               d_ecall ? `EXC_ECALL_U | {3'b0, priv} :
                                         `EXC_BREAKPOINT;
                e_tval      <= illegal ? TV_IR : d_ecall ? TV_ZERO : TV_PC;
                e_xret      <= !trap && (d_mret || d_sret);
                e_fret      <= !trap && d_fret;
                e_csr       <= !trap && d_csr;
                e_mul       <= !trap && d_mul;
                e_div       <= !trap && d_div;
                e_shift     <= !trap && d_shift;
                e_branch    <= !trap && d_branch;
                e_jump      <= !trap && (d_jal || d_jalr);
                e_mem       <= !trap && (d_load || d_store || d_amo || d_lr || d_sc);
                e_wb        <= !trap && !(d_mret || d_sret || d_fret || d_csr ||
                                          d_mul || d_div || d_shift || d_branch ||
                                          d_jal || d_jalr || d_load || d_store ||
                                          d_amo || d_lr || d_sc);
                e_flush     <= !trap && d_sfence;
                e_flush_all <= rs1 == 5'b0;
            end
            st[S_DECODE]: begin
                case (opcode)
                    7'b0110111, 7'b0010111: imm <= imm_u;
                    7'b1101111: imm <= imm_j;
                    7'b1100011: imm <= imm_b;
                    7'b0100011: imm <= imm_s;
                    7'b0101111: imm <= 32'b0;
                    7'b1110011: imm <= imm_z;
                    default:    imm <= imm_i;
                endcase
            end
            st[S_EXEC]: begin
                wb_we <= d_rd_we;
                acc   <= d_load ? `ACC_LOAD : d_store ? `ACC_STORE :
                         d_lr ? `ACC_LR : d_sc ? `ACC_SC : `ACC_AMO;
                size  <= d_size;
                taken <= (funct3[2:1] == 2'b00 ? alu_eq :
                          funct3[2:1] == 2'b10 ? alu_lt : alu_ltu) ^ funct3[0];
                // Bit 1 of the jump target without waiting for the adder.
                jump_misaligned <= d_jalr ? rf_a_data[1] ^ imm[1] ^
                                            (rf_a_data[0] & imm[0]) : imm[1];
                shamt      <= d_b_imm ? imm[4:0] : rf_b_data[4:0];
                shamt_zero <= (d_b_imm ? imm[4:0] : rf_b_data[4:0]) == 5'd0;
                shift_fill <= funct7[5] & funct3[2] & rf_a_data[31];
                shift_rev  <= funct3 == 3'b001;
                shift_ld   <= 1'b0;
            end
            st[S_BRANCH]: pc_done <= taken;
            st[S_JUMP]: pc_done <= 1'b1;
            st[S_AMO_CMP]: begin
                case (d_alu_op)
                    `ALU_MIN:  amo_pick_a <= alu_lt;
                    `ALU_MAX:  amo_pick_a <= ~alu_lt;
                    `ALU_MINU: amo_pick_a <= alu_ltu;
                    default:   amo_pick_a <= ~alu_ltu;
                endcase
            end
            st[S_SHIFT]: begin
                logic [4:0] n;
                if (BARREL_SHIFT != 0)
                    n = 5'd0;
                else
                    n = shamt[4:3] != 2'b00 ? shamt - 5'd8 : shamt - 5'd1;
                if (!shamt_zero) begin
                    shamt      <= n;
                    shamt_zero <= n == 5'd0;
                end
            end
            st[S_TRAP1]: trap_to_s_q <= trap_to_s;
            st[S_TRAP4]: begin
                resv_valid <= 1'b0;
                if (trap_to_s_q) begin
                    m_spp  <= priv[0];
                    m_spie <= m_sie;
                    m_sie  <= 1'b0;
                    priv   <= `PRIV_S;
                end else begin
                    m_mpp  <= priv;
                    m_mpie <= m_mie;
                    m_mie  <= 1'b0;
                    priv   <= `PRIV_M;
                end
            end
            st[S_FENT3]: begin
                f_cause <= fev_cause;
                f_pprv  <= priv;
                is_f    <= 1'b1;
            end
            st[S_XRET3]: begin
                if (d_mret) begin
                    priv   <= m_mpp;
                    m_mie  <= m_mpie;
                    m_mpie <= 1'b1;
                    m_mpp  <= `PRIV_U;
                    if (m_mpp != `PRIV_M) m_mprv <= 1'b0;
                end else begin
                    priv   <= {1'b0, m_spp};
                    m_sie  <= m_spie;
                    m_spie <= 1'b1;
                    m_spp  <= 1'b0;
                    m_mprv <= 1'b0;
                end
            end
            st[S_FRET4]: begin
                priv       <= f_pprv;
                is_f       <= 1'b0;
                trap_cause <= finj_cause;
                trap_intr  <= 1'b0;
                tval_src   <= TV_ADDR;
                imm        <= {27'b0, finj_cause};
                finj_valid <= 1'b0;
                finj_cause <= 5'b0;
            end
            default: ;
        endcase

        // Trap/F event requests from any state.  The cause is staged in imm
        // to be written through the ALU.
        if (raise_trap) begin
            trap_cause <= raise_cause;
            trap_intr  <= raise_intr;
            tval_src   <= raise_tval;
            imm        <= {raise_intr, 26'b0, raise_cause};
        end
        if (raise_fev) begin
            fev_cause <= raise_fcause;
            tval_src  <= raise_tval;
        end

        // F mode load/store bus errors.
        if (is_f && ((st[S_R] && axi_rvalid && axi_rresp[1]) ||
                     (st[S_B] && axi_bvalid && axi_bresp[1])))
            f_berr <= 1'b1;

        if (reset) begin
            st         <= '0;
            st[S_FETCH] <= 1'b1;
            priv       <= `PRIV_M;
            is_f       <= 1'b1;
            resv_valid <= 1'b0;
            m_sie      <= 1'b0;
            m_mie      <= 1'b0;
            m_spie     <= 1'b0;
            m_mpie     <= 1'b0;
            m_spp      <= 1'b0;
            m_mpp      <= `PRIV_U;
            m_mprv     <= 1'b0;
            m_sum      <= 1'b0;
            m_mxr      <= 1'b0;
            m_tvm      <= 1'b0;
            m_tw       <= 1'b0;
            m_tsr      <= 1'b0;
            f_pprv     <= `PRIV_M;
            f_berr     <= 1'b0;
            f_cause    <= `FEV_RESET;
            finj_valid <= 1'b0;
            finj_cause <= 5'b0;
        end

        // Flop CSR writes.
        if (csr_ff_write) begin
            case (c_sel)
                C_MSTATUS: begin
                    m_sie  <= alu_result[1];
                    m_mie  <= alu_result[3];
                    m_spie <= alu_result[5];
                    m_mpie <= alu_result[7];
                    m_spp  <= alu_result[8];
                    if (alu_result[12:11] != 2'b10) m_mpp <= alu_result[12:11];
                    m_mprv <= alu_result[17];
                    m_sum  <= alu_result[18];
                    m_mxr  <= alu_result[19];
                    m_tvm  <= alu_result[20];
                    m_tw   <= alu_result[21];
                    m_tsr  <= alu_result[22];
                end
                C_SSTATUS: begin
                    m_sie  <= alu_result[1];
                    m_spie <= alu_result[5];
                    m_spp  <= alu_result[8];
                    m_sum  <= alu_result[18];
                    m_mxr  <= alu_result[19];
                end
                C_FSTATUS: begin
                    if (alu_result[1:0] != 2'b10) f_pprv <= alu_result[1:0];
                    f_berr <= alu_result[2];
                end
                C_FCAUSE: f_cause <= alu_result[2:0];
                C_FINJECT: begin
                    finj_valid <= alu_result[31];
                    finj_cause <= alu_result[4:0];
                end
                C_FTLBIDX: ftlbidx <= alu_result[3:0];
                C_FTLBHI: ftlbhi <= {alu_result[31:12], alu_result[1:0]};
                default: ;
            endcase
        end
    end

    // Other flop CSRs that don't interact with the main sequencing.
    always_ff @(posedge clk) begin
        if (csr_ff_write) begin
            case (c_sel)
                C_MEDELEG: medeleg <= alu_result[15:0] & 16'hb3ff;
                C_MIDELEG: mideleg <= {alu_result[9], alu_result[5], alu_result[1]};
                C_MIE: mie_r <= {alu_result[11], alu_result[9], alu_result[7],
                                 alu_result[5], alu_result[3], alu_result[1]};
                C_SIE: begin
                    if (mideleg[2]) mie_r[4] <= alu_result[9];
                    if (mideleg[1]) mie_r[2] <= alu_result[5];
                    if (mideleg[0]) mie_r[0] <= alu_result[1];
                end
                C_MIP: begin
                    seip_sw <= alu_result[9];
                    stip    <= alu_result[5];
                    ssip    <= alu_result[1];
                end
                C_SIP: if (mideleg[0]) ssip <= alu_result[1];
                C_MCOUNTEREN: mcounteren <= alu_result[2:0];
                C_SCOUNTEREN: scounteren <= alu_result[2:0];
                default: ;
            endcase
        end
        if (st[S_CSR5] && csr_write && c_sel == C_BRAM &&
            c_bram_idx == `RF_SATP)
            satp_mode <= alu_result[31];

        if (reset) begin
            medeleg    <= 16'b0;
            mideleg    <= 3'b0;
            mie_r      <= 6'b0;
            seip_sw    <= 1'b0;
            stip       <= 1'b0;
            ssip       <= 1'b0;
            mcounteren <= 3'b0;
            scounteren <= 3'b0;
            satp_mode  <= 1'b0;
        end
    end

    // Counters: 32-bit with wraps raising F mode events.
    always_ff @(posedge clk) begin
        if (csr_ff_write && c_sel == C_MCYCLE) begin
            mcycle <= alu_result;
        end else begin
            mcycle <= mcycle + 32'd1;
            if (&mcycle) f_cywrap <= 1'b1;
        end

        if (st[S_FETCH]) instret_written <= 1'b0;
        if (csr_ff_write && c_sel == C_MINSTRET) begin
            minstret        <= alu_result;
            instret_written <= 1'b1;
        end else if (retire && !is_f && !instret_written) begin
            minstret <= minstret + 32'd1;
            if (&minstret) f_irwrap <= 1'b1;
        end

        // sfence.vma below F mode raises an F mode event.
        if (st[S_EXEC] && e_flush && !is_f) f_sfpend <= 1'b1;

        if (csr_ff_write && c_sel == C_FSTATUS) begin
            f_cywrap <= alu_result[8];
            f_irwrap <= alu_result[9];
            f_sfpend <= alu_result[10];
        end
        if (st[S_FENT3]) begin
            if (fev_cause == `FEV_CYWRAP) f_cywrap <= 1'b0;
            if (fev_cause == `FEV_IRWRAP) f_irwrap <= 1'b0;
            if (fev_cause == `FEV_SFENCE) f_sfpend <= 1'b0;
        end

        if (reset) begin
            mcycle   <= 32'b0;
            minstret <= 32'b0;
            f_cywrap <= 1'b0;
            f_irwrap <= 1'b0;
            f_sfpend <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // AXI
    // ------------------------------------------------------------------
    wire [2:0] axprot = {acc_fetch, 1'b0, is_f || priv != `PRIV_U};

    assign axi_araddr  = pa;
    assign axi_arsize  = {1'b0, size};
    assign axi_arprot  = axprot;
    assign axi_arvalid = st[S_AR];
    assign axi_rready  = st[S_R];
    assign axi_awaddr  = pa;
    assign axi_awsize  = {1'b0, size};
    assign axi_awprot  = axprot;
    assign axi_awvalid = st[S_AW] && !aw_done;
    assign axi_wdata   = wdata;
    assign axi_wstrb   = wstrb;
    assign axi_wvalid  = st[S_AW] && !w_done;
    assign axi_bready  = st[S_B];

    // ------------------------------------------------------------------
    // Status and trace
    // ------------------------------------------------------------------
    assign halted = st[S_HALT];

    logic [31:0] ipc;  // PC of the instruction being executed
    always_ff @(posedge clk) if (st[S_FETCH]) ipc <= pc;

    // The epc and tval are written to the register file through the ALU.
    always_ff @(posedge clk) begin
        if (st[S_TRAP1]) dbg_trap_epc <= alu_result;
        if (st[S_TRAP3]) dbg_trap_tval <= alu_result;
        if (st[S_TRAP4]) dbg_trap_cause <= {trap_intr, trap_cause};
    end

    assign trace_retire = retire;
    assign trace_trap   = st[S_TRAP4];
    assign trace_fevent = st[S_FENT3];
    assign trace_pc     = ipc;
    assign trace_insn   = ir;
    assign trace_priv   = {is_f, priv};
    assign trace_rd_we  = st[S_WB] && wb_we;
    assign trace_rd     = rd;
    assign trace_rd_val = result;
    assign trace_cause  = st[S_FENT3] ? {3'b0, fev_cause} :
                          {trap_intr, trap_cause};

endmodule
