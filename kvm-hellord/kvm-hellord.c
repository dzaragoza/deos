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

static const uint8_t code[] = {
    0xfa, 0x31, 0xc0, 0x8e, 0xd8, 0x8e, 0xc0, 0x8e, 0xd0, 0xbc, 0x00, 0x70,
    0x0f, 0x01, 0x16, 0x82, 0x7c, 0x0f, 0x20, 0xc0, 0x66, 0x83, 0xc8, 0x01,
    0x0f, 0x22, 0xc0, 0xea, 0x20, 0x7c, 0x08, 0x00, 0x66, 0xb8, 0x10, 0x00,
    0x8e, 0xd8, 0x8e, 0xc0, 0x8e, 0xd0, 0xbc, 0x00, 0x70, 0x00, 0x00, 0x0f,
    0x20, 0xe0, 0x83, 0xc8, 0x20, 0x0f, 0x22, 0xe0, 0xb8, 0x00, 0x10, 0x00,
    0x00, 0x0f, 0x22, 0xd8, 0xb9, 0x80, 0x00, 0x00, 0xc0, 0x0f, 0x32, 0x0d,
    0x00, 0x01, 0x00, 0x00, 0x0f, 0x30, 0x0f, 0x20, 0xc0, 0x0d, 0x00, 0x00,
    0x00, 0x80, 0x0f, 0x22, 0xc0, 0xea, 0x60, 0x7c, 0x00, 0x00, 0x18, 0x00,
    0xbf, 0x00, 0x80, 0x0b, 0x00, 0xbe, 0x78, 0x7c, 0x00, 0x00, 0x31, 0xc0,
    0xb4, 0x0f, 0xac, 0x84, 0xc0, 0x74, 0x04, 0x66, 0xab, 0xeb, 0xf7, 0xf4,
    0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x72, 0x64, 0x21, 0x0a, 0x00, 0x1f, 0x00,
    0x00, 0x05, 0x00, 0x00,
};

int main(void)
{
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) { perror("open /dev/kvm (modprobe kvm first)"); return 1; }

    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    CHECK(vm);

    uint8_t *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) { perror("mmap guest ram"); return 1; }
    memset(ram, 0, RAM_SIZE);

    memcpy(ram + CODE_ADDR, code, sizeof code);

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

    CHECK(ioctl(vcpu, KVM_RUN, 0));
    if (run->exit_reason != KVM_EXIT_HLT) {
        fprintf(stderr, "unexpected exit reason %d\n", run->exit_reason);
        return 1;
    }

    for (size_t j = 0; j < strlen(msg); j++)
        putchar(ram[VGA_TEXT + 2 * j]);
    return 0;
}
