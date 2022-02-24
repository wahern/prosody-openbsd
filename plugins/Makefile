include ../common.mk

.PHONY: all
all:

T.mod_unveil.lua = $(modulesdir)/mod_unveil.lua

$(DESTDIR)$(T.mod_unveil.lua): mod_unveil.lua
	mkdir -p $(@D)
	cp -p mod_unveil.lua $@

.PHONY: install
install: $(DESTDIR)$(T.mod_unveil.lua)

.PHONY: clean
clean:
