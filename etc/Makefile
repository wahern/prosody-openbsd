include ../common.mk

.PHONY: all
all:

$(DESTDIR)$(pkgsysconfdir)/openbsd.cfg.lua: openbsd.cfg.lua
	mkdir -p $(@D)
	cp -p openbsd.cfg.lua $@

.PHONY: install
install: $(DESTDIR)$(pkgsysconfdir)/openbsd.cfg.lua

.PHONY: clean
clean:
