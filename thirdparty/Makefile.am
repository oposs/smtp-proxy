#  Copyright (C) 2019 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign
export PATH := /usr/gnu/bin:$(PATH)

THIRDPARTY_DIR := $(shell pwd)

# THIRDPARTY_DIST := $(shell test -d cache && find cache -type f )
CPANSNAPV := cpanfile-$(shell $(PERL) -MConfig -e 'my $$v =$$Config{version}; $$v =~ s/\.\d+$$//;print $$v;').snapshot

# The dependency tree in lib/perl5 is only valid for the perl it was built with:
# the XS modules are compiled for one version/architecture, while the pure perl
# ones are not. A mixed tree is worse than an empty one, because cpanm treats an
# already importable module as satisfied and then never installs its (arch
# dependent) prerequisites. So stamp the tree with the identity of its perl and
# refuse to build on top of a tree belonging to a different one.
PERLID := $(shell $(PERL) -MConfig -e 'print "$$Config{version}-$$Config{archname}"')
STAMP := touch-$(PERLID)

#EXTRA_DIST = $(THIRDPARTY_DIST) $(wildcard bin/cpanm)
EXTRA_DIST = bin/cpanm $(wildcard cpanfile*snapshot)
PERL_ENV := PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) PERL_CARTON_PATH=$(THIRDPARTY_DIR)
CARTON_ENV := $(PERL_ENV) PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5
CARTON := $(THIRDPARTY_DIR)/carton/bin/carton

# carton and cpanm are order only prerequisites: having to (re)install the
# installer says nothing about the dependency tree being out of date, and
# letting it trigger $(CPANSNAPV) would rewrite the checked in snapshot as a
# side effect of an ordinary build.
all-local: $(STAMP)

$(STAMP):  $(CPANSNAPV) | bin/cpanm $(CARTON)
	$(AM_V_at)if test -d lib && test ! -f $(STAMP); then \
	    echo "** ERROR: thirdparty/lib was built for a different perl than"; \
	    echo "**        $(PERL)"; \
	    echo "**        (this tree has no $(STAMP))"; \
	    echo "**        Discard the stale tree and build again:"; \
	    echo "**            cd thirdparty && $(MAKE) clean-local && $(MAKE)"; \
	    exit 1; \
	fi
	$(AM_V_at)echo "** Installing Dependencies using carton and $(CPANSNAPV)"
	$(AM_V_at)cp $(CPANSNAPV) ../cpanfile.snapshot
	cd .. && $(CARTON_ENV) $(PERL) $(CARTON) install --deployment
	$(AM_V_at)rm -f ../cpanfile.snapshot
	$(AM_V_at)touch $(STAMP)

$(CARTON): bin/cpanm
	$(AM_V_at)echo "** Installing Carton"
	$(PERL_ENV) $(PERL) bin/cpanm -q --notest --local-lib-contained $(THIRDPARTY_DIR)/carton Carton

bin/cpanm:
	$(AM_V_at)mkdir -p bin
	$(URL_CAT) https://cpanmin.us > bin/cpanm
	$(AM_V_at)chmod 755 bin/cpanm

$(CPANSNAPV): ../cpanfile | $(CARTON)
	$(AM_V_at)echo "** Installing Dependencies using Carton install"
	$(AM_V_at)test -f $(CPANSNAPV) && cp $(CPANSNAPV) ../cpanfile.snapshot || true
	cd .. && $(CARTON_ENV) $(PERL) $(CARTON) install
	$(AM_V_at)mv ../cpanfile.snapshot $(CPANSNAPV)
	$(AM_V_at)touch $(STAMP)

update: $(CPANSNAPV) | $(CARTON)
	$(AM_V_at)echo "** Updating Dependencies using Carton update"
	$(AM_V_at)cp $(CPANSNAPV) ../cpanfile.snapshot
	cd .. && $(CARTON_ENV) $(PERL) $(CARTON) update
	$(AM_V_at)mv ../cpanfile.snapshot $(CPANSNAPV)

clean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile |grep -v bin | xargs rm -rf

distclean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile | xargs rm -rf

install-exec-hook:
	cp -fr lib/perl5/* $(DESTDIR)$(libdir)
