include ../common.mk

.PHONY: all
all:

T.mod_openbsd.lua = $(modulesdir)/mod_openbsd.lua

$(DESTDIR)$(T.mod_openbsd.lua): mod_openbsd.lua
	mkdir -p $(@D)
	cp -p mod_openbsd.lua $@

.PHONY: install
install: $(DESTDIR)$(T.mod_openbsd.lua)

.PHONY: clean
clean:
