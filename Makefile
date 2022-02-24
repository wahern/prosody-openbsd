include common.mk

SUBDIRS = plugins util-src etc

.DEFAULT_GOAL = all     # GNU default goal
.MAIN: $(.DEFAULT_GOAL) # OpenBSD default goal

.DEFAULT:
	@for D in $(SUBDIRS); do (set -x; $(MAKE) -C $${D} $<;); done
