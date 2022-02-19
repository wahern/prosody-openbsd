include ../common.mk

.PHONY: all
all:

$(DESTDIR)$(pkglibdir)/modules/mod_openbsd.lua: mod_openbsd.lua
	mkdir -p $(@D)
	cp -p mod_openbsd.lua $@

.PHONY: install
install: $(DESTDIR)$(pkglibdir)/modules/mod_openbsd.lua

.PHONY: clean
clean:
