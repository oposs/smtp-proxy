#  Copyright (C) <%= ${year} %> <%= ${fullName} %>

AUTOMAKE_OPTIONS =  foreign

SUBDIRS = bin lib thirdparty

PERLTESTS := $(shell find -L t -name "*.t")
PERLTESTLIBS := $(shell find -L t -name "*.pm")
PM := $(shell find -L lib -name "*.pm")

EXTRA_DIST = VERSION cpanfile COPYRIGHT LICENSE CHANGES AUTHORS bootstrap $(PUB) $(wildcard t/*.t) $(POD) $(TEMPL) $(PERLTESTS) $(PERLTESTLIBS) $(SHARE)

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)
nobase_data_DATA = $(PUB) $(TEMPL) $(SHARE)

README.md COPYRIGHT: VERSION
	$(PERL) -i -p -e 's/(#VERSION#|\d+\.\d+\.\d+[^.\s]*)/$(PACKAGE_VERSION)/g;s/(#YEAR#|20[1-9]\d)/$(YEAR)/g;s/(#DATE#|20[1-9]\d-[01]\d-[0-3]\d)/$(DATE)/g;' $@



# The recipe below is indented with a tab. It was three spaces, which made
# automake read it as a variable assignment rather than a recipe, so the
# target had an empty body and `make test` reported "Nothing to be done"
# and succeeded without running anything.
test:
	MOJO_REACTOR=Mojo::Reactor::EV LIBEV_FLAGS=4 prove -w -Ilib -Ithirdparty/lib/perl5 -It t/
