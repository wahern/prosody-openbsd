include ../common.mk

CFLAGS = -O2 -g
CPPFLAGS =
LDFLAGS =
LDLIBS =
SOFLAGS = -shared

LUA_CFLAGS =
LUA_CPPFLAGS = -I/usr/local/include/lua-$(LUA_VERSION)
LUA_LDFLAGS =
LUA_LDLIBS =
LUA_VERSION = 5.2

PIC_CFLAGS = -fPIC
PIC_CPPFLAGS =
PIC_LDFLAGS =
PIC_LDLIBS =

WARN_CFLAGS = -Wall -Wextra
WARN_CPPFLAGS =
WARN_LDFLAGS =
WARN_LDLIBS =

ALL_CFLAGS = $(LUA_CFLAGS) $(PIC_CFLAGS) $(WARN_CFLAGS) $(CFLAGS) $(MYCFLAGS)
ALL_CPPFLAGS = $(LUA_CPPFLAGS) $(PIC_CPPFLAGS) $(WARN_CPPFLAGS) $(CPPFLAGS) $(MYCPPFLAGS)
ALL_LDFLAGS = $(LUA_LDFLAGS) $(PIC_LDFLAGS) $(WARN_LDFLAGS) $(LDFLAGS) $(MYLDFLAGS)
ALL_LDLIBS = $(LUA_LDLIBS) $(PIC_LDLIBS) $(WARN_LDLIBS) $(LDLIBS) $(MYLDLIBS)
ALL_SOFLAGS = $(SOFLAGS) $(MYSOFLAGS)

openbsd.so: openbsd.c Makefile
	$(CC) -o $@ openbsd.c $(ALL_CFLAGS) $(ALL_SOFLAGS) $(ALL_CPPFLAGS) $(ALL_LDFLAGS) $(ALL_LDLIBS)

.PHONY: all
all: openbsd.so

$(DESTDIR)$(pkglibdir)/util/openbsd.so: openbsd.so
	mkdir -p $(@D)
	cp -p openbsd.so $@

.PHONY: install
install: $(DESTDIR)$(pkglibdir)/util/openbsd.so

.PHONY: clean
clean:
	rm -f openbsd.so
