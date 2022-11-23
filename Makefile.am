#  Copyright (C) <%= ${year} %> <%= ${fullName} %>

AUTOMAKE_OPTIONS =  foreign

SUBDIRS = bin lib thirdparty

PERLTESTS := $(shell find -L t -name "*.t")
PM := $(shell find -L lib -name "*.pm")

EXTRA_DIST = VERSION cpanfile COPYRIGHT LICENSE CHANGES AUTHORS bootstrap $(PUB) $(wildcard t/*.t) $(POD) $(TEMPL) $(PERLTESTS) $(SHARE)

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)
nobase_data_DATA = $(PUB) $(TEMPL) $(SHARE)

README.md COPYRIGHT: VERSION
	$(PERL) -i -p -e 's/(#VERSION#|\d+\.\d+\.\d+[^.\s]*)/$(PACKAGE_VERSION)/g;s/(#YEAR#|20[1-9]\d)/$(YEAR)/g;s/(#DATE#|20[1-9]\d-[01]\d-[0-3]\d)/$(DATE)/g;' $@



test:
   MOJO_REACTOR=Mojo::Reactor::EV LIBEV_FLAGS=4 prove -w
