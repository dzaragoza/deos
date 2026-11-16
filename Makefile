all:
	$(MAKE) -C kvm-hellord

run: all
	$(MAKE) -C kvm-hellord run

clean:
	$(MAKE) -C kvm-hellord clean

.PHONY: all run clean
