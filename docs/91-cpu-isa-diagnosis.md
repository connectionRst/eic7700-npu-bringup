# ruapu a.out SIGSEGV diagnosis

## Symptom
`ssh debian@<board-ip>` (RISC-V64), running `~/ruapu/a.out` -> crashes with
SIGSEGV (exit 139), zero output. `ruapu` is *supposed* to never crash.

## Environment
- CPU ISA (from /proc/cpuinfo): `rv64imafdch_zicntr_zicsr_zifencei_zihpm_zba_zbb_sscofpmf`
  -> **NO Vector (`v`) extension.**
- Kernel: `6.6.88-win2030` on host `EZN-Schwitch`, has the H (virtualization) bit.
  CSR reads (e.g. misa/vlenb) and vector-exception handling are non-standard here.

## Root cause
The crash is inside `ruapu_init()` during the probe for **`xsmtvfmadotf32`**
(last `PROBE:` line before death, core backtrace #0 = `ruapu_some_xsmtvfmadotf32`,
#1 `ruapu_detect_isa`, #2 `ruapu_init`).

That probe emits `vfmadot.v v2,v0,v0` = `.word 0xea00012b` -> **opcode 0x2b = OP-V
(RISC-V Vector) instruction space**. It is a *raw* vector instruction with no
`csrr vcsr` (RVV1.0-availability) guard.

On this CPU/kernel an unimplemented OP-V instruction is NOT reported as a plain
illegal instruction (SIGILL) as on a normal RISC-V kernel. Instead the vector
exception machinery raises it and the kernel delivers **SIGSEGV as a fatal
exception that bypasses userspace signal handlers**. Evidence:
- Bare `vfmadot` (no handler at all) -> SIGSEGV; fault lands in the probe's
  epilogue `ld ra, 8(sp)` with a corrupted `sp=0xfffffffffffffea0` (matches core).
- A standalone SIGSEGV handler is never even entered for `vfmadot` (process dies
  139 with no handler output), whereas a normal data-access SIGSEGV (store to
  addr 0) IS caught and recovered.
- Sibling probes `xsfv*` (opcode 0x5b, NOT OP-V) raise SIGILL and are caught fine.

ruapu installs SIGILL+SIGSEGV handlers and sigsetjmp/siglongjmp recovery. It
recovers from normal SIGILL / data-access SIGSEGV, but **cannot recover from this
vector-exception SIGSEGV** -> uncaught -> abort. No output because the crash is
before `ruapu_init()` returns.

## Why the user's partial fix was insufficient
A local edit had commented out only `RUAPU_ISAENTRY(xsmtvfmadotf32)`; after
`git reset --hard` it was restored to HEAD (9 active xsmtv entries). Even that
single comment would not have been enough: the other 8 OP-V xsmtv entries
(`xsmtvfwmadotf16`, `xsmtvmadothpi4/8`, `xsmtvmadoti4/8/ni8`, `xsmtvnspack`,
`xsmtvpack`) are raw OP-V probes too and would crash next.

## Fix (verified)
Comment out all 9 Xsmtv map entries (`sed 's/^RUAPU_ISAENTRY(xsmt/\/\/RUAPU_ISAENTRY(xsmt/' ruapu.h`), rebuild.
Result: exit 0, 123 lines. CPU correctly reported as Vector-less (v=0; all
zve/zvbb/zvl/xsv/xsmtv/xtheadvector = 0) with correct scalar features.

(Upstream note: on a standard RISC-V kernel an unimplemented OP-V instr -> SIGILL,
which ruapu catches, so this is specific to this virtualized kernel's vector
exception handling.)

## Corroboration from web search (search 2)

NOT directly confirmed: no ruapu GitHub issue reports this exact
`xsmtvfmadotf32`/OP-V SIGSEGV crash. But the surrounding facts are confirmed:

1. ruapu's OWN design assumes unsupported instructions -> SIGILL.
   nihui/ruapu README: "determines whether the CPU supports certain instruction
   sets by trying to execute instructions and detecting whether an `Illegal
   Instruction` exception occurs" and "does not rely on ... MISA". FAQ explains
   only that debuggers/sims (gdb/qemu-user) capture the signal; on real HW it
   expects SIGILL. => On a normal system vfmadot would be SIGILL and ruapu recovers.

2. Standard no-V RISC-V hardware gives SIGILL, not SIGSEGV.
   riseproject-dev/riscv-runner#49 (2026-06): real RVV-less nodes report
   `isa: rv64imafdcsu` (no v) and a plain `rv64gcv` vector probe traps with
   "SIGILL rc=132 (illegal insn)". Analogous ISA to our machine but a normal
   kernel => SIGILL. So the fatal SIGSEGV here is environment-specific, not
   inherent to ruapu + no-V.

3. Kernel traps.c (torvalds/android kernel/common):
   - `do_trap_insn_illegal` -> DO_ERROR_INFO(SIGILL, ILL_ILLOPC).
   - `riscv_v_first_use_handler()` re-enables V and re-executes a vector insn
     ONLY if `has_vector()` is true; else falls through to SIGILL.
   - `do_trap()` uses `force_sig_fault()`. A "machine fatal exception"
     (MSIE=0 / M-mode) bypasses userspace handlers -> matches our finding that
     the SIGSEGV handler was never even entered.

4. Vector + signal-handler crashes on EMULATED RISC-V are a known class:
   - CVE-2024-35873 "riscv: Fix vector state restore in rt_sigreturn()": after a
     signal handler returns, vector state is corrupted and the app crashes.
     (Corroborates the garbage sp / crash-in-epilogue we saw.)
   - qemu QEMU#1976 (Cuttlefish AOSP): CPU "thinks RVV is enabled
     (MSTATUS_VS)" but vector instrs fail -> random SIGILL at first vector insn.
     (Matches a kernel/emulator that advertises V yet can't really exec it.)
   - XUANTIE-RV/xuantie-gnu-toolchain#24 (author = nihui): fp16 vector intrinsic
     segfaults under `qemu-riscv64 -cpu c906fdv`. Direct precedent for vector
     code segfaulting on an emulated RISC-V target.
   - qemu-user Ubuntu 26.04 (Launchpad 2133188): intermittent SIGILL in vector
     memset, "vector state not restored by signal handler".

## Conclusion on "confirmed or not"
- CONFIRMED pattern: invalid/unimplemented OP-V vector instruction on a
  non-standard / virtualized / emulated RISC-V can surface as a fatal SIGSEGV
  that ruapu's SIGILL/SIGSEGV siglongjmp recovery cannot handle; on standard
  no-V hardware the same instruction is a catchable SIGILL.
- NOT confirmed: a ruapu-specific bug report for this exact probe; the precise
  mcause here (misa/vlenb CSR reads themselves SIGILL'd, consistent with a
  truncated/emulated CSR surface).
- Practical: dropping the 9 raw-OP-V `xsmtv` map entries is a robust workaround
  regardless of whether the root defect is in this kernel or in ruapu's probes,
  because this CPU has no Vector unit anyway (those probes would all report 0).

## Bare-metal / EIC7700X refinement (search + on-box test 2)

Confirmed hardware: **Pine64 StarPro64 = ESWIN EIC7700X, quad-core SiFive P550,
"RV64GBC"** (no V). P550 device tree declares isa-extensions without "v". No
hypervisor flag; /sys/board is DT "Pine64 StarPro64" => bare-metal.

### The smoking gun: kernel config vs hardware
/boot/config-$(uname -r):
  CONFIG_RISCV_ISA_V=y
  CONFIG_RISCV_ISA_V_DEFAULT_ENABLE=y      <-- vector ENABLED by default
So `has_vector()` is effectively TRUE even though misa/isa have no `v`.

### Per-instruction signal map on THIS box (default disposition, exit code)
  vsetvli / vsetvl / vfadd.vv / vadd.vv(vm=0) / csrr vcsr   -> SIGILL (132) catchable
  vfmadot  (xsmtv, .word 0xea00012b)                          -> SIGSEGV (139) FATAL
  SpacemiT vmadot 0x8200302b (from binutils xsmtvdot patch)   -> ok (no crash)
Changing the SEW field of 0xea00012b (010/001/110) still -> SIGSEGV.

### Interpretation
- ruapu's *guarded* RVV probes (zve*/zvbb*/...) all start with `csrr vcsr`
  (RUAPU_RVV1P0_AVAIL). On this box csrr vcsr -> SIGILL (catchable), so they
  report "unsupported" and ruapu continues. That is why execution reached the
  xsmtv probes.
- ruapu's *xsmtv* probes are RAW OP-V instructions (no csrr vcsr guard).
  Because the kernel thinks V is present, the OP-V goes through the vector
  exception path and this specific encoding surfaces as a fatal SIGSEGV that
  siglongjmp recovery cannot survive (fault lands in the probe epilogue
  `ld ra,8(sp)` with sp=0xfffffffffffffea0, matching the core).
- The fact that the *SpacemiT-recommended* encoding (0x8200302b, per the
  binutils xsmtvdot gas patch) does NOT crash while ruapu's 0xea00012b does is
  a strong hint that **ruapu's xsmtv encodings are wrong** (they differ from
  the SpacemiT IME / binutils encoding and carry an invalid SEW). Worth a PR.

### Bottom line (revised root cause)
Two compounding defects:
  1. Kernel: CONFIG_RISCV_ISA_V_DEFAULT_ENABLE=y on a no-V CPU (EIC7700X/P550),
     so OP-V probes are routed to a fatal vector-exception SIGSEGV instead of
     catchable SIGILL. (On a standard no-V kernel — e.g. riseproject riscv-runner
     #49 — the same vector instr is SIGILL and ruapu works.)
  2. ruapu: unguarded raw-OP-V `xsmtv*` probes + suspect encodings (0xea00012b
     vs SpacemiT 0x8200302b) that hit that fatal path.

### Fix (still verified)
Comment out all 9 `xsmtv` map entries -> a.out runs cleanly (exit 0, 123 lines),
correctly reporting this CPU as Vector-less. Longer-term: kernel should not set
vector-on-default on a no-V hart, and ruapu should fix the xsmtv encodings (and
guard them like the other RVV probes).
