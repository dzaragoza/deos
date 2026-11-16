# deos guest: enter 64-bit long mode at ring 0, drop to ring 3 (user mode),
# print "Hellord!" from CPL3 to the VGA text buffer, exit via syscall.
#
# Build: the Makefile assembles this flat and links it at 0x7C00
#   (ld -Ttext=0x7C00), producing guest.bin, which kvm-hellord.c
#   embeds with .incbin and copies to guest physical 0x7C00.
#
# Host setup (kvm-hellord.c) before the first KVM_RUN:
#   - vCPU starts in 16-bit real mode, CS:IP = 0:0x7C00, IF=0
#   - GDT at physical 0x500, 7 entries:
#       0x00 null
#       0x08 ring-0 32-bit code   0x10 ring-0 32-bit data   (mode transition)
#       0x18 ring-0 64-bit code   0x20 ring-0 64-bit data   (kernel)
#       0x28 ring-3 64-bit code   0x30 ring-3 data         (user)
#   - identity page tables: PML4 @0x1000 -> PDPT @0x2000 -> PD @0x3000,
#     PD[0] = 2 MiB page at physical 0 with U/S=1 (user-accessible),
#     covering code, stacks and VGA @0xB8000
#   - MSR_LSTAR = 0x7E00 (syscall_handler below), MSR_STAR selects
#     kernel CS 0x18 / user CS 0x28

.global start

.code16
start:
    cli                     # no interrupts; IF stays 0 the whole run
    xorw %ax, %ax
    movw %ax, %ds           # flat real-mode segments, base 0
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp       # real-mode stack below the code

    lgdt gdt_desc           # GDTR := { limit 0x37, base 0x500 }

    movl %cr0, %eax
    orl $1, %eax            # CR0.PE = 1  -> protected mode
    movl %eax, %cr0
    ljmp $0x08, $pm32       # far jump: CS := GDT 0x08 (32-bit code)

.code32
pm32:
    movw $0x10, %ax         # GDT 0x10: 32-bit data
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x7000, %esp

    movl %cr4, %eax
    orl $0x20, %eax         # CR4.PAE = 1  (required for long mode)
    movl %eax, %cr4

    movl $0x1000, %eax      # CR3 = PML4 (page tables already in guest RAM)
    movl %eax, %cr3

    movl $0xC0000080, %ecx  # MSR_EFER
    rdmsr
    orl $0x101, %eax        # EFER.LME = 1 (long mode) | EFER.SCE = 1 (syscall)
    wrmsr

    movl %cr0, %eax
    orl $0x80000000, %eax   # CR0.PG = 1  -> paging on; PAE+LME+PG = IA-32e
    movl %eax, %cr0
    ljmp $0x18, $lm64       # far jump: CS := GDT 0x18 (64-bit code)

.code64
lm64:                       # ---- ring 0 kernel ----
    movw $0x20, %ax         # GDT 0x20: ring-0 64-bit data
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x7000, %esp      # kernel stack

    # Drop to ring 3: iretq pops RIP, CS, RFLAGS, RSP, SS (pushed in reverse).
    # Selectors get RPL=3 (0x2B = 0x28|3, 0x33 = 0x30|3).
    pushq $0x33             # SS: user data
    pushq $0x6000           # RSP: user stack
    pushq $0x2              # RFLAGS: IF=0
    pushq $0x2B             # CS: user 64-bit code
    pushq $user_code        # RIP
    iretq

user_code:                  # ---- ring 3 user mode ----
    movl $0xB8000, %edi     # VGA text buffer (user-accessible page)
    movl $msg, %esi         # the string, stored below
    xorl %eax, %eax
    movb $0x0F, %ah         # attribute: white on black
1:  lodsb                   # al = [rsi], rsi++
    testb %al, %al
    jz 2f                   # NUL -> done
    stosw                   # [rdi] = ax (char + attribute), rdi += 2
    jmp 1b
2:  syscall                 # CPL3 -> CPL0 via MSR_LSTAR, RCX = return RIP

msg:
    .ascii "Hellord!\n\0"

.org 0x200                  # lands at physical 0x7E00 (0x7C00 + 0x200)
syscall_handler:            # MSR_LSTAR target, runs at ring 0: just halt
    hlt                     # -> KVM_EXIT_HLT on the host

gdt_desc:                   # GDTR image for lgdt above
    .word 0x37              # limit: 7 entries * 8 - 1
    .long 0x500             # base
