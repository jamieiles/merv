# merv architecture

merv (Millicode Enhanced RISC-V) is a small RV32IMA core (M, S and U modes,
Sv32) aimed at high Fmax and a low LUT count on Spartan-7, at the expense of
IPC.  Instructions execute through a multi-cycle state machine with a single
AXI4 port shared between instruction fetch and data with only one transaction
in flight.  There are no caches.

Features that are rare or expensive to implement in hardware are implemented
in firmware running in a non-standard privilege level, **F mode**, which is
more privileged than M mode and invisible to it.

This document is the contract between the instruction set simulator
(`sim/`), the F mode firmware (`firmware/ffw/`) and the RTL (`rtl/`).

## Build time configuration

| Parameter      | Default      | Description                                                     |
| -------------- | ------------ | --------------------------------------------------------------- |
| `TLB_ENTRIES`  | 4            | Number of fully associative unified TLB entries (2-16)          |
| `NATIVE_AMO`   | 1            | AMOs in hardware, else emulated by F mode with LR/SC            |
| `HW_DIV`       | 1            | Unsigned DIV/DIVU/REM/REMU in hardware, else emulated by F mode |
| `BARREL_SHIFT` | 0            | Single cycle shifter, else 8 or 1 bits per cycle                |
| `RESET_VECTOR` | `0x40000000` | M mode entry point after the F mode firmware has initialized    |
| `HART_ID`      | 0            | Hart ID (0-255) in `fconfig`, emulated `mhartid`                |
| `AXI_EXCLUSIVE`| 0            | LR/SC and AMOs use AXI exclusive accesses (SMP)                 |

## Privilege levels

| Level | Encoding (internal) | Notes                                                    |
| ----- | ------------------- | -------------------------------------------------------- |
| U     | 0                   |                                                          |
| S     | 1                   |                                                          |
| M     | 3                   |                                                          |
| F     | 4                   | Non-interruptible, never translated, private GPR bank    |

The 2-bit privilege values written to `mstatus.MPP`, `fstatus.PPRV` etc. use the
standard U/S/M encodings, F is never visible to a lower privilege level.

### Reset

The core resets into F mode with `pc = 0x00000000` and `fcause = 0`.  The
firmware initializes its state, sets `fstatus.PPRV = M` and `fepc = fbootvec`
and executes `fret` to enter M mode at the reset vector.  M mode state is
reset as per the privileged specification (`mstatus.MIE = 0`, `MPRV = 0`,
`satp.MODE = 0` etc).

### F mode entry

TLB misses (causes 1-3) vector to `0x00000004`, reset and all other events to
`0x00000000`, so the TLB miss handler needs neither a dispatch on `fcause` nor
a jump.  On entry:

- `fepc` is written with the PC of the instruction that was interrupted (or
  that must be emulated/retried),
- `fcause` is written with the event cause,
- `ftval` is written with the faulting virtual address or instruction bits,
- `fpaddr` is written with the physical address for AMO emulation,
- `fstatus.PPRV` is written with the privilege level the event was taken from,
- the privilege level becomes F.

| `fcause` | Event                     | `ftval`               | `fepc`                       |
| -------- | ------------------------- | --------------------- | ---------------------------- |
| 0        | Reset                     | 0                     | 0                            |
| 1        | Instruction TLB miss      | faulting VA           | PC of the instruction        |
| 2        | Load TLB miss             | faulting VA           | PC of the instruction        |
| 3        | Store/AMO TLB miss        | faulting VA           | PC of the instruction        |
| 4        | `mcycle` wrapped          | 0                     | PC of the next instruction   |
| 5        | `minstret` wrapped        | 0                     | PC of the next instruction   |
| 6        | Instruction emulation     | instruction bits      | PC of the instruction        |
| 7        | `sfence.vma` executed     | see below             | PC of the next instruction   |

For `sfence.vma` (cause 7), `ftval` is 0 if `rs1` is `x0`, otherwise the value
of `rs1` ORed with its register number: bits [31:12] are the page and the
value is never zero.

Instruction emulation (cause 6) is raised for:

- any CSR access instruction to a CSR address that is not implemented in
  hardware (see [CSRs](#csrs)),
- AMO instructions (not LR/SC) when `NATIVE_AMO = 0`.  The event is raised
  after the address has been checked for alignment, translated and the store
  permissions checked, `fpaddr` holds the physical address,
- DIV/DIVU/REM/REMU when `HW_DIV = 0`, and DIV/REM with a negative operand
  when `HW_DIV = 1` (the hardware divider is unsigned only).

The firmware completes the instruction, writes the destination register through
the F-RAM register window, increments `minstret` and returns to `fepc + 4`, or
injects an exception.

### Event priority

At an instruction boundary, when not in F mode, the core checks in order:

1. a pending `sfence.vma` event (cause 7), then a pending `mcycle` wrap
   (cause 4), then a pending `minstret` wrap (cause 5),
2. pending and enabled interrupts (standard priority: MEI, MSI, MTI, SEI, SSI,
   STI),
3. the instruction fetch (translation: TLB miss, page fault; then access fault),
4. decode: illegal instruction, emulation, ECALL/EBREAK, misaligned jump target,
5. data access: misaligned address, TLB miss, page fault, access fault.

Taking a wrap event clears the corresponding pending flag in `fstatus`.
Wrap events that occur while in F mode remain pending and are taken at the
first instruction boundary after `fret`.  The firmware can observe and clear
the pending flags in `fstatus` to fold them in itself.

### Exceptions in F mode

The firmware must not take exceptions.  An illegal instruction, ECALL, EBREAK,
misaligned access or an instruction fetch bus error in F mode halts the core
(the simulator reports a fatal error).  Bus errors on F mode loads and stores
do not trap: the load returns 0 and the sticky `fstatus.BERR` flag is set.

### F-RAM

The F mode firmware lives in an 8KB private RAM at `0x00000000-0x00001fff`.
It is only decoded for instruction fetches, loads and stores made in F mode.
Lower privilege levels accessing the same address go out over AXI where it
must decode to an error, resulting in an access fault.  The F-RAM is
initialized with the firmware image at configuration time (FPGA) or loaded by
the simulator; it is not accessible over the bus.

Because F mode accesses are physical and F-RAM decodes in F mode, the firmware
must never dereference a physical address supplied by a lower privilege level
(page table pointers, AMO emulation addresses) that falls within the F-RAM
range.  Such accesses are reported as access faults to the lower level.

The top 512 bytes of the F-RAM are the register window, the storage of the
GPRs and of the CSRs that the RTL keeps in block RAM:

| Offset            | Contents                                      |
| ----------------- | --------------------------------------------- |
| `0x1e00-0x1e7f`   | bank 0 (U/S/M) GPRs `x0`-`x31`                |
| `0x1e80-0x1eff`   | bank 1 (F) GPRs `x0`-`x31`                    |
| `0x1f00-0x1fff`   | reserved                                      |

Loads and stores (including sub-word) in the GPR range access the registers
directly.  The firmware must not write `x0` of either bank (the hardware has
no special case and it would no longer read as zero, the simulator halts) and
must not access the reserved range or fetch instructions from the window.

### GPR banks

There are two banks of 32 GPRs: bank 0 used by U, S and M modes and bank 1
used by F mode.  The F mode bank persists across events so the firmware does
not need to save or restore any state and can keep long lived values in
registers.  F mode accesses bank 0 with loads and stores to the F-RAM
register window.

## F mode CSRs

These are only accessible in F mode, any access from a lower privilege level
raises an illegal instruction exception (not an emulation event).  `0x7c6`
and `0x7c7` are unallocated and behave like any other unimplemented CSR.

| Address | Name       | Access | Description                                                          |
| ------- | ---------- | ------ | -------------------------------------------------------------------- |
| `0x7c0` | `fstatus`  | RW     | see below                                                            |
| `0x7c1` | `fepc`     | RW     | return PC, bits [1:0] read as zero                                   |
| `0x7c2` | `fcause`   | RW     | event cause                                                          |
| `0x7c3` | `ftval`    | RW     | event value, also the `tval` for an injected exception               |
| `0x7c4` | `fpaddr`   | RW     | physical address for AMO emulation                                   |
| `0x7c5` | `finject`  | RW     | bit 31 valid, bits [4:0] exception cause, cleared by `fret`          |
| `0x7c8` | `ftlbidx`  | RW     | TLB entry index for `ftlbhi`/`ftlblo` writes                         |
| `0x7c9` | `ftlbhi`   | W      | [31:12] VPN, [1] SUPER, [0] V                                        |
| `0x7ca` | `ftlblo`   | W      | [31:12] PPN, [3] U, [2] X, [1] W, [0] R; writing commits the entry   |
| `0x7cb` | `fbootvec` | RO     | `RESET_VECTOR`                                                       |
| `0x7cc` | `fconfig`  | RO     | [7:0] `TLB_ENTRIES`, [8] `NATIVE_AMO`, [9] `HW_DIV`, [10] `BARREL_SHIFT`, [31:24] `HART_ID` |

`fstatus`:

| Bits  | Name   | Description                                                      |
| ----- | ------ | ---------------------------------------------------------------- |
| [1:0] | PPRV   | privilege level to return to with `fret`                         |
| [2]   | BERR   | sticky, set by an F mode load/store bus error, write 0 to clear  |
| [8]   | CYWRAP | `mcycle` wrap pending, write 0 to clear                          |
| [9]   | IRWRAP | `minstret` wrap pending, write 0 to clear                        |
| [10]  | SFPEND | `sfence.vma` event pending, write 0 to clear                     |

`ftlbhi` holds the tag that is written to the entry selected by `ftlbidx` when
`ftlblo` is written.  Writing `ftlbhi` with V clear and then `ftlblo`
invalidates an entry.  `ftlbhi` and `ftlblo` are write-only and read as zero.

### `fret`

`fret` is encoded as `0xf0200073` (SYSTEM, funct12 = `0xf02`) and is only
legal in F mode.

- If `finject[31]` is clear, the core returns to `fepc` at privilege level
  `fstatus.PPRV`.
- If `finject[31]` is set, the core sets the privilege level to `fstatus.PPRV`
  and then takes the synchronous exception `finject[4:0]` exactly as if the
  instruction at `fepc` had raised it, with `tval = ftval`, honoring
  `medeleg`.

`finject` is cleared by `fret`.

## Memory management

There is no hardware page table walker.  Translation uses a unified, fully
associative TLB of `TLB_ENTRIES` entries, each holding:

- V, valid,
- SUPER, a 4MB megapage: VPN[9:0] are not compared and come from the VA,
- VPN[19:0],
- PPN[19:0], only 32-bit physical addresses are supported,
- R, W, X, U permissions.

Translation is active for instruction fetches when the privilege level is S or
U, and for loads/stores when the effective privilege (taking `mstatus.MPRV` and
`MPP` into account) is S or U, and `satp.MODE = 1`.  F mode is never
translated.

On a TLB hit, the hardware checks permissions using the effective privilege,
`mstatus.SUM` and `mstatus.MXR` and raises a page fault directly through the
normal trap logic.  On a miss, the core takes an F mode event (cause 1, 2 or 3).
LR is a load and AMOs and SC are store accesses for the purposes of
translation.

At least two TLB entries are required: an instruction may need both a fetch
and a data translation and with a single entry each refill would evict the
other.

There are no ASIDs (`satp.ASID` is read-only zero and `rs2` of `sfence.vma` is
ignored).  `sfence.vma` with `rs1 = x0` invalidates all TLB entries, otherwise
it invalidates the entries that translate the address in `rs1` (a megapage
entry for any address within it).  An `sfence.vma` executed below F mode also
sets `fstatus.SFPEND`, raising an F mode event (cause 7) before the next
instruction is translated so that the firmware can invalidate any translations
it caches itself.  Linux flushes single pages after updating a PTE,
so this keeps the rest of the TLB and the firmware's second level TLB.

### Firmware page table walk

The firmware performs the Sv32 walk:

- a PTE with V = 0, or W = 1 and R = 0 is a page fault,
- a non-leaf PTE at level 0 is a page fault,
- a misaligned megapage (PPN[9:0] != 0) is a page fault,
- a leaf with A = 0 is a page fault (Svade),
- a leaf whose PPN has bits [21:20] set is an access fault,
- a bus error reading a PTE, or a PTE address within the F-RAM range, is an
  access fault,
- otherwise the entry is written into the TLB with W cleared if D = 0 so the
  first store to a clean page raises a store page fault (Svade).

Faults are injected with `finject` using the instruction (12), load (13) or
store/AMO (15) page fault cause, or the instruction (1), load (5) or store (7)
access fault cause.

## Counters

`mcycle` and `minstret` are 32 bits wide in hardware.  `mcycle` counts every
clock cycle, `minstret` counts instructions retired at U, S and M.  When either
increments from `0xffffffff` to `0x00000000`, the corresponding wrap flag is
set in `fstatus` and an F mode event is raised at the next instruction
boundary.  The firmware maintains the upper 32 bits and emulates `mcycleh`,
`minstreth`, `cycleh` and `instreth`.

The `time`/`timeh` CSRs are emulated by the firmware reading the CLINT `mtime`
register.

A CSR write to `mcycle` or `minstret` takes precedence over the increment for
that instruction.

## CSRs

Implemented in hardware:

| CSR                       | Notes                                                                        |
| ------------------------- | ---------------------------------------------------------------------------- |
| `mstatus`/`sstatus`       | SIE, MIE, SPIE, MPIE, SPP, MPP, MPRV, SUM, MXR, TVM, TW, TSR                 |
| `mtvec`/`stvec`           | direct mode only, MODE is read-only zero                                     |
| `mepc`/`sepc`             | bits [1:0] read as zero                                                      |
| `mcause`/`scause`         | WLRL, all bits stored                                                        |
| `mtval`/`stval`           |                                                                              |
| `mscratch`/`sscratch`     |                                                                              |
| `mie`/`sie`, `mip`/`sip`  | MEI, SEI, MTI, STI, MSI, SSI; `mip.SEIP` reads as the external interrupt OR the software bit, except for CSR instructions that write `mip` which use only the software bit |
| `medeleg`                 | bits 0-9, 12, 13, 15 writable                                                |
| `mideleg`                 | SEI, STI, SSI writable                                                       |
| `mcounteren`/`scounteren` | CY, TM, IR                                                                   |
| `satp`                    | MODE, PPN[21:0]; ASID read-only zero                                         |
| `mcycle`/`minstret`       | 32-bit                                                                       |
| `cycle`/`instret`         | read-only shadows, gated by `mcounteren`/`scounteren`                        |
| F mode CSRs               | see above                                                                    |

Standard privilege checks apply to hardware CSRs (CSR address bits [9:8] versus
the current privilege, read-only CSRs, `mstatus.TVM` for `satp`, counter
enables for `cycle`/`instret`) and raise an illegal instruction exception
directly.

An access to any other CSR address from U, S or M mode raises an instruction
emulation event.  The firmware implements:

| CSR                                                   | Behaviour                         |
| ----------------------------------------------------- | --------------------------------- |
| `misa`                                                | RV32IMASU, writes ignored         |
| `mvendorid`, `marchid`, `mimpid`, `mconfigptr`        | read-only zero                    |
| `mhartid`                                             | `fconfig[31:24]`, read-only       |
| `mstatush`, `medelegh`                                | zero, writes ignored              |
| `menvcfg`, `menvcfgh`, `senvcfg`                      | zero, writes ignored              |
| `mcountinhibit`                                       | zero, writes ignored              |
| `tselect`, `tdata1-3`                                 | zero, writes ignored (no triggers) |
| `pmpcfg0-3`, `pmpaddr0-15`                            | zero, writes ignored (no PMP)     |
| `mhpmcounter3-31(h)`, `mhpmevent3-31`                 | zero, writes ignored              |
| `hpmcounter3-31(h)`                                   | zero (subject to counter enables) |
| `mcycleh`, `minstreth`                                | upper 32 bits, writable (a write to `minstreth` suppresses the `minstret` increment) |
| `cycleh`, `instreth`, `time`, `timeh`                 | subject to counter enables        |

with the standard privilege checks.  Anything else results in an injected
illegal instruction exception with `tval` holding the instruction bits.

## Exceptions and interrupts

- `mtval`/`stval` hold the faulting VA for misaligned, access and page faults,
  the instruction bits for illegal instructions and 0 for ECALL/EBREAK
  (EBREAK writes the PC).
- Misaligned loads and stores raise address misaligned exceptions (emulated by
  OpenSBI), the alignment check is performed before translation.  LR/SC/AMOs
  must be naturally aligned.
- Instruction address misaligned exceptions are raised by the jump/branch with
  `tval` holding the target.
- Bus errors (`SLVERR`/`DECERR`) raise access faults.
- `WFI` is implemented as a NOP (subject to `mstatus.TW` in S mode and illegal
  in U mode).
- `FENCE` and `FENCE.I` are NOPs.

## Atomics

LR/SC are implemented in hardware with a single reservation (valid flag and
the physical word address).  LR sets the reservation, SC succeeds when the
reservation is valid for the same physical address, and clears the
reservation whether it succeeds or not.  M/S trap entry also clears the
reservation; F mode events do not, so a TLB miss between an LR and SC does not
prevent forward progress.

With `NATIVE_AMO = 1` the AMO is performed as a load, ALU operation and store
by the state machine.  With `NATIVE_AMO = 0` an emulation event is raised after
translation and the firmware performs an LR/op/SC loop on `fpaddr`.

With `AXI_EXCLUSIVE = 0` the AXI accesses are all normal ones, and LR/SC and
AMOs are only atomic with a single manager.  With `AXI_EXCLUSIVE = 1`, for
atomicity between harts, LR and the load of an AMO are AXI exclusive reads (`ARLOCK`) and SC and the store of an AMO exclusive writes
(`AWLOCK`).  An exclusive write that doesn't get `EXOKAY` was not performed:
the SC fails (rd = 1), the AMO retries from its load.  The SC is only issued
on the bus when the core's own reservation matches, otherwise it fails
without a bus access.  The exclusive monitors are in the memory (on the Arty,
one per port in the DDR3 bridge: an exclusive read sets it, a write by
another port to the word clears it).  A subordinate without a monitor must
give `EXOKAY` to exclusive writes, which gives single hart semantics.

The ISS executes one instruction per hart in turn, so its AMOs are atomic, and
a store by one hart clears the reservations of the others on the same word.

## Physical memory map

| Base          | Size  | Device                                        |
| ------------- | ----- | --------------------------------------------- |
| `0x00000000`  | 8KB   | F-RAM (F mode only)                           |
| `0x40000000`  | 64KB  | Boot ROM                                      |
| `0x80000000`  | 128MB (sim) / 256MB (Arty) | DRAM                       |
| `0xf0000000`  | 48KB  | CLINT (`msip` 0x0 + 4h, `mtimecmp` 0x4000 + 8h, `mtime` 0xbff8) |
| `0xf000c000`  | 4KB   | syscon / test finisher                        |
| `0xf8000000`  | 4MB   | PLIC, context 2h = M, context 2h + 1 = S of hart h |
| `0xfffc0000`  | 64KB  | SDHCI (Arty)                                  |
| `0xfffe0000`  | 64KB  | SPI (Arty)                                    |
| `0xffff1000`  | 4KB   | 16550 UART, `reg-shift = 2`, 32-bit access    |

The syscon register at offset 0 is compatible with the SiFive test finisher:
`0x5555` powers off (simulation exits with status 0), `0x3333 | code << 16`
powers off with a failure code and `0x7777` resets.

## F mode firmware

The firmware (`firmware/ffw/`) has the TLB miss handler at `0x00000004` and
everything else behind a jump at `0x00000000`:

- reset (`fcause == 0`) sets up the stack and global pointer and the fast
  path's constants (preserved in the F mode GPR bank between events),
  invalidates the TLB and returns to M mode at `fbootvec`,
- TLB misses first look in a second level TLB in the F-RAM: 256 direct
  mapped 4KB page entries indexed by the VPN, then 64 megapage entries
  indexed by `VPN[1]`, holding the `ftlbhi`/`ftlblo` values with an epoch in
  `ftlbhi[10:4]`.  A hit refills the TLB in ~16 instructions without touching
  DRAM.  Each translation is in exactly one entry so an `sfence.vma` event
  with an address clears the two entries for it, one for everything
  increments the epoch so that all older entries stop matching (the table is
  only cleared when the epoch wraps),
- on a second level miss, an assembly fast path walks the page tables for
  valid, accessed, aligned leaf PTEs that are outside of the F-RAM range (two
  loads and five CSR writes) and inserts the translation into the second
  level TLB.  Anything else falls back to the C walker which repeats the walk
  and injects the fault,
- the remaining events are handled in C: counter wraps, CSR emulation, AMO
  emulation (LR/SC loop on `fpaddr`) and division.

Shifts are iterative in the core (8 or 1 bits per cycle) so the fast path
masks with constants held in `s3`-`s5`, `s7` and `s8` instead.  `s6`, `s10`
and `s11` hold the second level TLB tag bits for the current epoch, the TLB
replacement index (round robin) and the number of entries.  All are reserved
from the C compiler.  The firmware is built for
`rv32ia_zicsr` so that it never uses the instructions that it may have to
emulate.

## Microarchitecture (RTL)

`rtl/MervCore.sv` is a multi-cycle state machine with a one-hot state
register.  Every state boundary is registered: the next state logic is a set
of independent one-hot equations and the ALU control (operation and operand
selects) is registered from the next state, so the datapath is driven
straight from flops.  Traps and F mode events enter through a state that
doesn't use the ALU so that their ALU control is computed without the trap
detection logic.

The datapath is built around a single ALU (`rtl/MervALU.sv`) with 4:1
operand multiplexers (`rs1`, `pc`, `result`, `addr` and `rs2`, `imm`, `ir`,
4).  Almost every register loads only from the ALU, using pass operations to
move values, including the CSR and trap state written to the register file
block RAM.  The ALU has a single adder/subtractor, a per-bit logic function
and an output select; shifts are performed by the core in a SHIFT state that
shifts right by 8 or 1 bits per cycle, or by the whole amount with
`BARREL_SHIFT = 1` (with bit reversal for left shifts), and sub-word loads
are aligned by the same shifter.

| Instruction class            | States (excluding memory latency)                        |
| ---------------------------- | -------------------------------------------------------- |
| Fetch                        | FETCH, [TLB1, TLB2,] ACC, AR, R                          |
| ALU                          | DECODE, DECODE2, EXEC, WB                                |
| Branch, jump                 | DECODE, DECODE2, EXEC, BRANCH/JUMP, WB                   |
| Load/store                   | ... EXEC, XLATE, [TLB1, TLB2,] ACC, AR/AW, R/B, WB       |
| Sub-word load                | + up to 3 (2 barrel) shift states and a sign extension   |
| Shift                        | ... EXEC, 1-10 (1-2 barrel) SHIFT states, WB             |
| AMO                          | load + [CMP, PICK] + ALU + store                         |
| CSR                          | ... EXEC, CSR1-5, WB                                     |
| Trap                         | TRAP0-4                                                  |
| F mode event                 | FENT0-3                                                  |

The register file is the F-RAM register window, a single dual port block RAM
(`rtl/MervRAM.sv`) holds both.  The ports are read with the output register
(two cycle latency): port A reads `rs1`, a CSR or F-RAM load/fetch data,
port B reads `rs2` or the CSR source operand (staged in a scratch word) and is
the only write port, also used for F-RAM stores.  The F-RAM is only accessed
in the memory access states, where the register file ports are idle, and
loads use port A so that `rs2` is preserved for an AMO.

The TLB lookup is pipelined over two cycles: the VPN comparison registers a
hit vector, then the hit entry is selected, the permissions checked and the
physical address formed.  Interrupts and counter wraps are sampled during the
fetch state and taken in the following state.

The AXI4 manager has a single transaction in flight with AxLEN = 0, AxSIZE
from the access and AxPROT from the privilege level.  A bus error raises an
access fault (or sets `fstatus.BERR` in F mode).
