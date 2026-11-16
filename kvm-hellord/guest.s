# deos guest: print "Hellord!" from 64-bit long mode, then halt.
#
# Build: the Makefile assembles this flat and links it at 0x7C00
#   (ld -Ttext=0x7C00), producing guest.bin, which kvm-hellord.c
#   embeds with .incbin and copies to guest physical 0x7C00.
#
# Host setup (kvm-hellord.c) before the first KVM_RUN:
#   - vCPU starts in 16-bit real mode, CS:IP = 0:0x7C00, interrupts off
#   - GDT (4 entries) at physical 0x500:
#       0x00 null, 0x08 32-bit code, 0x10 32-bit data, 0x18 64-bit code
#   - identity page tables: PML4 @0x1000 -> PDPT @0x2000 -> PD @0x3000,
#     PD[0] = 2 MiB page at physical 0 (covers code, stack and VGA @0xB8000)

.code16
start:
    cli                     # no interrupts; we end with hlt anyway
    xorw %ax, %ax
    movw %ax, %ds           # flat real-mode segments, base 0
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp       # stack just below the code at 0x7C00

    lgdt gdt_desc           # GDTR := { limit 0x1f, base 0x500 }

    movl %cr0, %eax
    orl $1, %eax            # CR0.PE = 1  -> protected mode
    movl %eax, %cr0
    ljmp $0x08, $pm32       # far jump: load CS from GDT entry 1 (32-bit code)

.code32
pm32:
    movw $0x10, %ax         # GDT entry 2: 32-bit data segment
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x7000, %esp

    movl %cr4, %eax
    orl $0x20, %eax         # CR4.PAE = 1  -> PAE paging (required for long mode)
    movl %eax, %cr4

    movl $0x1000, %eax      # CR3 = PML4 (page tables already in guest RAM)
    movl %eax, %cr3

    movl $0xC0000080, %ecx  # MSR_EFER
    rdmsr
    orl $0x100, %eax        # EFER.LME = 1  -> long mode enabled
    wrmsr

    movl %cr0, %eax
    orl $0x80000000, %eax   # CR0.PG = 1  -> paging on; PAE+LME+PG = IA-32e
    movl %eax, %cr0
    ljmp $0x18, $lm64       # far jump: load CS from GDT entry 3 (L=1 -> 64-bit)

.code64
lm64:
    movl $0xB8000, %edi     # VGA text buffer (identity-mapped physical address)
    movl $msg, %esi         # the string, stored right after the code
    xorl %eax, %eax
    movb $0x0F, %ah         # attribute byte: white on black
1:  lodsb                   # al = [rsi], rsi++
    testb %al, %al
    jz 2f                   # NUL terminator -> done
    stosw                   # [rdi] = ax (char + attribute), rdi += 2
    jmp 1b
2:  hlt                     # -> KVM_EXIT_HLT on the host

msg:
    .ascii "Hellord!\n\0"

# GDTR image used by lgdt above: limit = 4 entries * 8 - 1, base = 0x500
gdt_desc:
    .word 0x1f
    .long 0x500
