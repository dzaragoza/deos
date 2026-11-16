# deos lab notebook

One entry per day, appended at the bottom in the form:

```
## YYYY-MM-DD — Day N: <title>
```

Newest entry last. Keep it factual: what we tried, what broke, why, and the fix.

---

## 2026-11-16 — Day 1: bare-metal "Hellord!" on raw KVM, grown into a ring-3 shell

### Goal
The simplest bare-metal program that runs on Linux KVM and prints `Hellord!` —
then keep going: 64-bit mode, user mode, interactive echo shell.

### Final state of the repo
```
Makefile                  # all / run / trace / clean, delegates to kvm-hellord/
.gitignore
NOTEBOOK.md               # this file
kvm-hellord/
├── Makefile              # builds guest.bin from guest.s, then kvm-hellord from the .c
├── guest.s               # the guest: documented asm, single source of truth
└── kvm-hellord.c         # the host VMM (userspace, raw KVM API via /dev/kvm)
```

Build/run/test (on an x86-64 Linux host with `/dev/kvm`):
```
make          # or: make -C kvm-hellord
make run      # prints Hellord!, then a "> " shell: type a line, it echoes; "exit" quits
make trace    # single-steps the vCPU, prints rip/cpl/cs.l/cr0/cr3/cr4/efer + insn bytes
```

### Architecture
Two halves:

- **Host VMM** (`kvm-hellord.c`, normal Linux userspace program): opens `/dev/kvm`,
  creates VM + 1 vCPU, maps 1 MiB guest RAM (anonymous mmap + `KVM_SET_USER_MEMORY_REGION`),
  pre-builds GDT + page tables in guest RAM, loads the guest at `0x7C00`, starts the vCPU
  in 16-bit real mode, then loops `KVM_RUN` handling exits. Output = VGA text buffer
  (`0xB8000`) read back from guest RAM and printed to stdout, flushed live on every exit.
- **Guest** (`guest.s` → `guest.bin`, embedded into the host binary via `.incbin`):
  real mode → protected mode → long mode (PAE, EFER.LME, CR0.PG) at ring 0, then `iretq`
  to a ring-3 code segment. The user program prints `Hellord!`, then loops:
  print `> `, `syscall 0x1000` (read line), echo, repeat; `exit` → `syscall 0` → `hlt`.

Guest memory map (all inside one identity-mapped 2 MiB page):

| guest phys | contents                                             |
|------------|------------------------------------------------------|
| 0x500      | GDT, 7 entries (null, k32 code/data, k64 code/data, u64 code 0x28, udata 0x30) |
| 0x1000     | PML4                                                 |
| 0x2000     | PDPT                                                 |
| 0x3000     | PD (entry 0 = 2 MiB page at phys 0, U/S=1 at all levels) |
| 0x6000     | user stack (grows down)                              |
| 0x7000     | kernel stack                                         |
| 0x7C00     | guest code (guest.bin)                               |
| 0x7E00     | syscall handler (MSR_LSTAR target)                   |
| 0x9000     | INPUT_BUF, filled by host on read syscall            |
| 0xB8000    | VGA text buffer (char+attr cells)                    |

Syscall ABI: `rax` = number. `0` = exit (handler `hlt`s → `KVM_EXIT_HLT`).
`0x1000` = read one line: handler does `out 0x600` → `KVM_EXIT_IO` → host reads stdin,
writes the line NUL-terminated to `0x9000`, resumes; handler `sysretq`s back to user.
(`syscall` only clobbers rcx/r11, so the user's VGA cursor in rdi survives.)

### Bug log (symptom → cause → fix, commit)
1. `mmap guest ram: No such device` — mmap of the KVM **VM fd** is not supported on
   newer kernels (ENODEV). Fix: anonymous `mmap` + `KVM_SET_USER_MEMORY_REGION`
   (`userspace_addr`). — `21f65ea`
2. `unexpected exit reason 8` (KVM_EXIT_SHUTDOWN = triple fault) after switching the
   guest to long mode — our hand-rolled CPUID had only leaf 0, so the guest CPUID
   advertised no long mode (leaf `0x80000001` EDX bit 29 `LM` missing) and KVM #GP'd
   the guest's `wrmsr` to `EFER.LME`. Fix: `KVM_GET_SUPPORTED_CPUID` →
   `KVM_SET_CPUID2` (what real VMMs do). — `60d7dfa`
3. `#PF` at CPL3 on the first user instruction (caught by CPU emulation) — the `U/S`
   bit was set only on the PD entry; protection is the AND across the whole walk, so
   PML4/PDPT entries need `U/S=1` too (`0x...7` at every level). — `aba4a2b`
4. Shell loop echoed `exit` forever — the `"exit"` compare used a hand-computed dword
   with swapped bytes (`0x74696578` instead of `0x74697865`). Fix: `cmpl exit_str, %eax`
   against an `.ascii "exit\0"` label, no magic numbers. — `fb7646b`
5. `ld: warning: cannot find entry symbol start` — `start` wasn't `.global`. — `ec7fa76`
6. `make run` → `exit reason 6 (MMIO write guest-phys=0x100000)`, VGA full of `> `:
   the shell loop never received input because on kernels ≥ ~6.13 **KVM no longer
   forwards unknown `vmcall` numbers to userspace** (`KVM_EXIT_HYPERCALL`) unless the
   VMM enables them per-number via `KVM_CAP_EXIT_HYPERCALL`; our `vmcall 0x1000` was
   swallowed in-kernel, the VGA cursor ran off the 1 MiB slot → MMIO. Fix: handler
   uses `out 0x600` (port IO) instead — `KVM_EXIT_IO` always fires. — `dbb5ccd`

### KVM facts worth remembering
- vCPU starts in 16-bit real mode; set `CS.base=0, CS.limit=0xFFFF, CS.db=0`,
  `RIP=0x7C00`, `RFLAGS=2` via `KVM_SET_SREGS`/`KVM_SET_REGS`.
- Guest RAM: anonymous mmap + `KVM_SET_USER_MEMORY_REGION` (never mmap the VM fd on
  new kernels). The vcpu fd mmap is only for the `kvm_run` struct.
- Give the vCPU the real CPUID (`KVM_GET_SUPPORTED_CPUID` → `KVM_SET_CPUID2`); a
  degenerate CPUID breaks long mode (no LM bit) and more.
- `KVM_EXIT_*` seen: 2 IO, 3 HYPERCALL, 4 DEBUG, 5 HLT, 6 MMIO, 8 SHUTDOWN.
  For MMIO/IO exits, RIP is already advanced past the faulting instruction.
- Single-step trace: `KVM_SET_GUEST_DEBUG` with `KVM_GUESTDBG_SINGLESTEP` →
  `KVM_EXIT_DEBUG` after each instruction (used by `make trace`).
- Unknown `vmcall` numbers: no userspace exit on kernels ≥ ~6.13 unless
  `KVM_CAP_EXIT_HYPERCALL`; prefer port IO for custom hypercalls.

### Design decisions
- Raw KVM API (no QEMU/BIOS) to keep the whole thing one readable C file + one .s file.
- Output via VGA text buffer at `0xB8000` read back by the host — no serial/IO ports
  needed for output; input via one IO port serviced by the host.
- Guest code in `guest.s` (documented asm), assembled to `guest.bin` by the Makefile,
  embedded with `.incbin` — no binary blobs in C, no assembler needed at build time
  beyond binutils for the guest.
- `make` as the build system (root delegates to subdirs); run.fish was added then
  removed — `make run` does the same.
- Commits go directly to `main` (project convention, no PRs).

### Verification approach
- `gcc -O2 -Wall -Wextra` clean; guest disassembled with `objdump` after every change.
- Guest executed under a CPU emulator (unicorn/TCG) with KVM's reset state, the same
  memory image and MSRs — this caught bugs 3 and 4 before they reached real KVM.
- On real KVM: `make run` / `make trace`; the trace mode's exit diagnostics
  (reason, rip, cpl, cr0/cr3/cr4/efer, MMIO phys_addr) pinpointed bug 6.

### Next steps (ideas)
- Move the guest out of asm into a freestanding C kernel (`-ffreestanding -nostdlib`,
  own `linker.ld`, C syscall table, C VGA/console driver); `guest.s` shrinks to the
  long-mode entry stub.
- More syscalls, a real command parser, maybe a timer interrupt (needs IDT + TSS).
- `KVM_CAP_EXIT_HYPERCALL` if we ever want vmcall-style hypercalls back.
