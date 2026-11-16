.code16
start:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp
    lgdt gdt_desc
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    ljmp $0x08, $pm32

.code32
pm32:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x7000, %esp
    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4
    movl $0x1000, %eax
    movl %eax, %cr3
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
    ljmp $0x18, $lm64

.code64
lm64:
    movl $0xB8000, %edi
    movl $msg, %esi
    xorl %eax, %eax
    movb $0x0F, %ah
1:
    lodsb
    testb %al, %al
    jz 2f
    stosw
    jmp 1b
2:
    hlt
msg:
    .ascii "Hellord!\n\0"

gdt_desc:
    .word 0x1f
    .long 0x500
