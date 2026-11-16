# deos guest: ring-0 kernel enters long mode, drops to ring 3; the user
# program prints "Hellord!", then runs a tiny shell loop: print "> ",
# read a line via syscall, echo it, repeat -- until the line is "exit".
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
#     all with U/S=1, PD[0] = 2 MiB page at physical 0 (covers code,
#     stacks, input buffer and VGA @0xB8000)
#   - MSR_STAR (kernel CS 0x18 / user CS 0x28), MSR_LSTAR = 0x7E00
#   - on `out` to port READ_PORT the host fills INPUT_BUF (0x9000) with
#     one line of stdin, NUL-terminated. (We use port IO, not vmcall:
#     since ~6.13 KVM swallows unknown hypercalls in-kernel unless the
#     VMM enables them via KVM_CAP_EXIT_HYPERCALL; IO exits always fire.)

.global start

.equ INPUT_BUF, 0x9000      # filled by the host on syscall SYS_READ
.equ SYS_READ, 0x1000       # syscall number: read one line into INPUT_BUF
.equ SYS_EXIT, 0            # syscall number: halt
.equ READ_PORT, 0x600       # IO port the ring-0 handler outs to ask the host for input

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

user_code:                  # ---- ring 3 user program ----
    movl $0xB8000, %edi     # VGA cursor (cell pointer)
    movl $msg, %esi
    xorl %eax, %eax
    movb $0x0F, %ah         # attribute: white on black
1:  lodsb                   # print "Hellord!\n"
    testb %al, %al
    jz 2f
    stosw                   # [rdi] = ax (char + attribute), rdi += 2
    jmp 1b

2:  shell_loop:             # ---- shell: prompt, read, echo, repeat ----
    movl $prompt, %esi
3:  lodsb                   # print "> "
    testb %al, %al
    jz 4f
    stosw
    jmp 3b

4:  movl $SYS_READ, %eax    # syscall 0x1000: read one line into INPUT_BUF
    syscall                 # -> syscall_handler -> vmcall -> host stdin

    # if the line is exactly "exit", leave the loop
    movl $INPUT_BUF, %esi
    movl (%rsi), %eax
    cmpl exit_str, %eax     # first 4 bytes == "exit"
    jne 5f
    cmpb $0, 4(%rsi)        # ...and NUL-terminated right after
    je .done

5:  movl $INPUT_BUF, %esi   # echo the line (rdi still at the next cell;
6:  lodsb                   # syscall only clobbers rcx/r11, so the VGA
    testb %al, %al          # cursor in rdi survives)
    jz 7f
    stosw
    jmp 6b
7:  movb $0x0A, %al         # newline after the echoed line
    stosw
    jmp 2b                  # back to the prompt

.done:
    movl $SYS_EXIT, %eax    # syscall 0: halt -> KVM_EXIT_HLT
    syscall

msg:
    .ascii "Hellord!\n\0"
prompt:
    .ascii "> \0"
exit_str:
    .ascii "exit\0"

.org 0x200                  # lands at physical 0x7E00 (0x7C00 + 0x200)
syscall_handler:            # MSR_LSTAR target, runs at ring 0
    cmpq $SYS_READ, %rax    # syscall number in rax
    je 1f
    hlt                     # SYS_EXIT: halt -> KVM_EXIT_HLT
1:  movw $READ_PORT, %dx
    outb %al, %dx           # IO exit to host (KVM_EXIT_IO): read a line into INPUT_BUF
    sysretq                 # return to user: rip=rcx, rflags=r11

gdt_desc:                   # GDTR image for lgdt above
    .word 0x37              # limit: 7 entries * 8 - 1
    .long 0x500             # base
