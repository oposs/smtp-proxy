#  Copyright (C) 2018 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign


SUBDIRS = thirdparty lib bin

PERLTESTS := $(shell find t -name "*.t")

THIRDPARTY_DIR := $(shell pwd)/thirdparty

EXTRA_DIST = VERSION PERL_MODULES COPYRIGHT LICENSE CHANGES AUTHORS bootstrap $(PERLTESTS) $(shell find corpus -type f)


YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)
nobase_data_DATA = $(PUB) $(TEMPL) $(SHARE)

README.md COPYRIGHT: VERSION
	$(PERL) -i -p -e 's/(#VERSION#|\d+\.\d+\.\d+[^.\s]*)/$(PACKAGE_VERSION)/g;s/(#YEAR#|20[1-4]\d)/$(YEAR)/g;s/(#DATE#|20[1-9]\d-[01]\d-[0-3]\d)/$(DATE)/g;' $@

dist-hook:
	$(PERL) -i -p -e 's/\$$VERSION\s*=\s*".+?";/\$$VERSION = "$(PACKAGE_VERSION)";/;'  $(distdir)/lib/$(MJ_CLASS).pm

test:
	prove -w

