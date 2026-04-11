include ../common.mk

.PHONY: all
all:

$(DESTDIR)$(modulesdir)/mod_ktrace.lua: mod_ktrace.lua
	mkdir -p $(@D)
	cp -p mod_ktrace.lua $@

$(DESTDIR)$(modulesdir)/mod_unveil.lua: mod_unveil.lua
	mkdir -p $(@D)
	cp -p mod_unveil.lua $@

.PHONY: install
install: $(DESTDIR)$(modulesdir)/mod_ktrace.lua
install: $(DESTDIR)$(modulesdir)/mod_unveil.lua

.PHONY: clean
clean:
