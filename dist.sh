#!/bin/sh
set -e
if ssh oepdown@freddie -- test -f public_html/hin/smtp-proxy-`cat VERSION`.tar.gz; then
   echo version $(cat VERSION) this version has already been published
   exit 1
fi
echo `cat VERSION` `date +"%Y-%m-%d %H:%M:%S %z"` `git config user.name` '<'`git config user.email`'>' >> CHANGES.new
echo >> CHANGES.new
echo ' -' >> CHANGES.new
echo >> CHANGES.new
cat CHANGES >> CHANGES.new && mv CHANGES.new CHANGES
$EDITOR CHANGES
rm -f config.status
./bootstrap
for x in 5.22.0 5.32.0; do
  xs=`echo $x| sed 's/.[0-9]*$//'`
  test thirdparty/cpanfile-$xx.snapshot -nt cpanfile && continue
  echo "Building dependencies for perl $x ($xs)"
  ./configure PERL=$PERLBREW_ROOT/perls/perl-$x/bin/perl
  cd thirdparty
  test -d lib && mv lib .lib-off
  make clean
  if [ -d .lib-$xs ]; then
     mv .lib-$xs lib
  fi
  make
  mv lib .lib-$xs
  make clean
  test -d .lib-off && mv .lib-off lib
  cd ..
done
./configure
make
TEST_IDACTIVATION_ENABLED=1 TEST_AC2TNG_ENABLED=1 make test
make dist
# cat smtp-proxy-`cat VERSION`.tar.gz ../distsecret | sha512sum > smtp-proxy-`cat VERSION`.tar.gz.sum
scp smtp-proxy-`cat VERSION`.tar.gz* oepdown@freddie:public_html/hin/
