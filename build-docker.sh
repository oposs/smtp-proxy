#!/bin/bash
#
# Script to build a docker image containing the smtp-proxy perl script
#
V=$(cat VERSION)
P=smtp-proxy
set -eo pipefail
rm -f config.status
./bootstrap
./configure
make
make test | tee ${P}-${V}.test-output.txt
make dist
docker build --build-arg V=${V} --pull --tag ${P}:${V} .
echo you can now run "'docker run ${P}:${V}'" enjoy!
# docker save ${P}:${V} --output ${P}-${V}.docker
# pixz ${P}-${V}.docker
# chmod 644 ${P}-${V}.docker.xz
