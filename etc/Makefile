include ../common.mk

.PHONY: all
all:

T.openbsd.cfg.lua = $(examplesdir)/openbsd.cfg.lua

$(DESTDIR)$(T.openbsd.cfg.lua): openbsd.cfg.lua
	mkdir -p $(@D)
	cp -p openbsd.cfg.lua $@

.PHONY: install
install: $(DESTDIR)$(T.openbsd.cfg.lua)

.PHONY: clean
clean:
