#!/usr/bin/env bash

set -e

docker buildx build --progress=plain -t openwrt:config --target configured .
docker run -it -v "$(pwd):/host" openwrt:config /bin/bash -c "cd /src/openwrt && make menuconfig && ./scripts/diffconfig.sh > /host/diffconfig.r5s.final && echo done"
