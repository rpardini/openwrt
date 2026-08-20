#!/usr/bin/env bash

set -e

declare target="${1:-"r5s"}"

docker buildx build \
	--progress=plain \
	--build-arg="MACHINE_ID=${target}" \
	"--build-arg=OPENWRT_CONFIG=diffconfig.${target}.final" \
	"--build-arg=RELEASE_VERSION=00000000-0000" \
	-t openwrt:r5s .

docker cp "$(docker create --rm openwrt:r5s):/out" ./