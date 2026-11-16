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

#define CHECK(call) do { if ((call) < 0) { perror(#call); return 1; } } while (0)

static const char msg[] = "Hellord!\n";

int main(void)
{
    uint8_t code[16 + 3 * sizeof(msg)];
    size_t n = 0;
    code[n++] = 0xB8; code[n++] = 0x00; code[n++] = 0xB8;
    code[n++] = 0x8E; code[n++] = 0xC0;
    code[n++] = 0x31; code[n++] = 0xFF;
    code[n++] = 0xB4; code[n++] = 0x0F;
    for (const char *p = msg; *p; p++) {
        code[n++] = 0xB0; code[n++] = (uint8_t)*p;
        code[n++] = 0xAB;
    }
    code[n++] = 0xF4;

    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) { perror("open /dev/kvm (modprobe kvm first)"); return 1; }

    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    CHECK(vm);

    uint8_t *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) { perror("mmap guest ram"); return 1; }
    memset(ram, 0, RAM_SIZE);
    memcpy(ram + CODE_ADDR, code, n);

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

    struct kvm_cpuid2 *cpuid = calloc(1, sizeof(*cpuid) + sizeof(cpuid->entries[0]));
    cpuid->nent = 1;
    cpuid->entries[0] = (struct kvm_cpuid_entry2) {
        .function = 0, .eax = 0,
        .ebx = 0x756e6547, .ecx = 0x6c65746e, .edx = 0x49656e69,
    };
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
