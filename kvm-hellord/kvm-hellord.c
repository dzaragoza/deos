#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/kvm.h>

#define CODE_ADDR 0x7C00
#define RAM_SIZE  0x100000
#define VGA_TEXT  0xB8000
#define GDT_ADDR  0x500
#define PML4_ADDR 0x1000
#define PDPT_ADDR 0x2000
#define PD_ADDR   0x3000

#define CHECK(call) do { if ((call) < 0) { perror(#call); return 1; } } while (0)

static const char msg[] = "Hellord!\n";

__asm__(
    ".section .rodata\n"
    ".global guest_code, guest_code_end\n"
    "guest_code:\n"
    ".incbin \"guest.bin\"\n"
    "guest_code_end:\n"
    ".previous\n"
);
extern const uint8_t guest_code[];
extern const uint8_t guest_code_end[];

int main(int argc, char **argv)
{
    int trace = argc > 1 && strcmp(argv[1], "trace") == 0;

    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) { perror("open /dev/kvm (modprobe kvm first)"); return 1; }

    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    CHECK(vm);

    uint8_t *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) { perror("mmap guest ram"); return 1; }
    memset(ram, 0, RAM_SIZE);

    memcpy(ram + CODE_ADDR, guest_code, guest_code_end - guest_code);

    uint64_t *pt = (uint64_t *)ram;
    pt[PML4_ADDR / 8] = PDPT_ADDR | 0x3;
    pt[PDPT_ADDR / 8] = PD_ADDR | 0x3;
    pt[PD_ADDR / 8] = 0x0 | 0x83;

    uint64_t gdt[] = {
        0,
        0x00CF9A000000FFFFULL,
        0x00CF92000000FFFFULL,
        0x00AF9A000000FFFFULL,
    };
    memcpy(ram + GDT_ADDR, gdt, sizeof gdt);

    struct kvm_userspace_memory_region region = {
        .slot = 0,
        .guest_phys_addr = 0,
        .memory_size = RAM_SIZE,
        .userspace_addr = (uint64_t)ram,
    };
    CHECK(ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region));

    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    CHECK(vcpu);

    size_t run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) { perror("mmap kvm_run"); return 1; }

    struct kvm_cpuid2 *cpuid = NULL;
    unsigned int n = 128;
    for (;;) {
        cpuid = calloc(1, sizeof(*cpuid) + n * sizeof(cpuid->entries[0]));
        cpuid->nent = n;
        if (ioctl(kvm, KVM_GET_SUPPORTED_CPUID, cpuid) == 0)
            break;
        if (errno != E2BIG) { perror("KVM_GET_SUPPORTED_CPUID"); return 1; }
        n = cpuid->nent;
        free(cpuid);
    }
    CHECK(ioctl(vcpu, KVM_SET_CPUID2, cpuid));
    free(cpuid);

    struct kvm_sregs sregs;
    CHECK(ioctl(vcpu, KVM_GET_SREGS, &sregs));
    sregs.cs.selector = 0;
    sregs.cs.base = 0;
    sregs.cs.limit = 0xFFFF;
    sregs.cs.db = 0;
    CHECK(ioctl(vcpu, KVM_SET_SREGS, &sregs));

    struct kvm_regs regs = { .rip = CODE_ADDR, .rflags = 2 };
    CHECK(ioctl(vcpu, KVM_SET_REGS, &regs));

    if (trace) {
        struct kvm_guest_debug dbg = { .control = KVM_GUESTDBG_SINGLESTEP };
        CHECK(ioctl(vcpu, KVM_SET_GUEST_DEBUG, &dbg));
    }

    for (;;) {
        CHECK(ioctl(vcpu, KVM_RUN, 0));
        if (trace && run->exit_reason == KVM_EXIT_DEBUG) {
            struct kvm_regs r;
            struct kvm_sregs s;
            ioctl(vcpu, KVM_GET_REGS, &r);
            ioctl(vcpu, KVM_GET_SREGS, &s);
            printf("rip=%#06llx cs.l=%u cr0=%#010llx cr4=%#06llx efer=%#06llx bytes=",
                   (unsigned long long)r.rip, s.cs.l,
                   (unsigned long long)s.cr0, (unsigned long long)s.cr4,
                   (unsigned long long)s.efer);
            for (unsigned i = 0; i < 8 && r.rip + i < RAM_SIZE; i++)
                printf("%02x ", ram[r.rip + i]);
            printf("\n");
            continue;
        }
        if (run->exit_reason == KVM_EXIT_HLT)
            break;
        struct kvm_regs r;
        ioctl(vcpu, KVM_GET_REGS, &r);
        fprintf(stderr, "unexpected exit reason %d at rip=%#llx\n",
                run->exit_reason, (unsigned long long)r.rip);
        return 1;
    }

    for (size_t j = 0; j < strlen(msg); j++)
        putchar(ram[VGA_TEXT + 2 * j]);
    return 0;
}
