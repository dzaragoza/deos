all:
	$(MAKE) -C kvm-hellord

run: all
	$(MAKE) -C kvm-hellord run

trace: all
	$(MAKE) -C kvm-hellord trace

clean:
	$(MAKE) -C kvm-hellord clean

.PHONY: all run trace clean
