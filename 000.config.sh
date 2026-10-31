#!/usr/bin/env bash

set -e

# Edit a board's config with menuconfig. r5s is the full base (diffconfig.r5s.final); any other board is stored
# as diffconfig.<board>.delta, holding only what differs from that base (see docker/compose-config.sh).
declare target="${1:-"r5s"}"

docker buildx build --build-arg "MACHINE_ID=r5s" --progress=plain -t openwrt:config --target configured .
docker run -it -v "$(pwd):/host" -e TARGET="${target}" openwrt:config /bin/bash -c '
	set -e
	cd /src/openwrt
	(cd /host && ./docker/compose-config.sh "${TARGET}") > .config
	make defconfig
	make menuconfig
	./scripts/diffconfig.sh > /tmp/new.diffconfig
	if [[ "${TARGET}" == "r5s" ]]; then
		cp /tmp/new.diffconfig /host/diffconfig.r5s.final
	else
		grep -vxFf /host/diffconfig.r5s.final /tmp/new.diffconfig > "/host/diffconfig.${TARGET}.delta" || true
		echo "base lines no longer present for ${TARGET} (cannot be expressed in a delta, edit the r5s base instead):"
		grep -vxFf /tmp/new.diffconfig /host/diffconfig.r5s.final | grep -v "_DEVICE_" || true
	fi
	echo done'
