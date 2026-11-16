CC     := gcc
CFLAGS := -O2 -Wall -Wextra

all: kvm-hellord

kvm-hellord: kvm-hellord.c guest.bin
	$(CC) $(CFLAGS) -o $@ kvm-hellord.c

guest.bin: guest.s
	as -o guest.o guest.s
	ld -Ttext=0x7C00 -e start -o guest.elf guest.o
	objcopy -O binary guest.elf $@
	rm -f guest.o guest.elf

run: kvm-hellord
	./kvm-hellord

trace: kvm-hellord
	./kvm-hellord trace

clean:
	rm -f kvm-hellord guest.bin guest.o guest.elf

.PHONY: all run trace clean guest.bin
