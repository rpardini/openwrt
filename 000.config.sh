#!/usr/bin/env bash

set -e

declare target="${1:-"r5s"}"

docker buildx build --build-arg "MACHINE_ID=${target}" --build-arg "OPENWRT_CONFIG=diffconfig.${target}.final" --progress=plain -t openwrt:config --target configured .
docker run -it -v "$(pwd):/host" openwrt:config /bin/bash -c "cd /src/openwrt && make menuconfig && ./scripts/diffconfig.sh > /host/diffconfig.${target}.final && echo done"
