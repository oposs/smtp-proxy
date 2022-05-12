#!/bin/bash
V=$(cat VERSION)
P=smtp-proxy
set -eo pipefail
if ssh oepdown@freddielx -- test -f public_html/hin/${P}-${V}.tar.gz; then
   echo version ${V} this version has already been published
   exit 1
fi

echo ${V} `date +"%Y-%m-%d %H:%M:%S %z"` `git config user.name` '<'`git config user.email`'>' >> CHANGES.new
echo >> CHANGES.new
echo ' -' >> CHANGES.new
echo >> CHANGES.new
cat CHANGES >> CHANGES.new && mv CHANGES.new CHANGES
$EDITOR CHANGES
rm -f config.status
./bootstrap
./configure
make
make test | tee ${P}-${V}.test-output.txt
make dist
docker build --build-arg V=${V} --pull --tag ${P}:${V} .
docker save ${P}:${V} --output ${P}-${V}.docker
pixz ${P}-${V}.docker
chmod 644 ${P}-${V}.docker.xz
cat ${P}-${V}.tar.gz distsecret | sha512sum > ${P}-${V}.tar.gz.sum
scp ${P}-${V}.docker.xz ${P}-${V}.tar.gz* ${P}-${V}.test-output.txt oepdown@freddielx:public_html/hin/
