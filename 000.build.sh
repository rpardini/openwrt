#!/usr/bin/env bash

set -e

docker buildx build \
	--progress=plain \
	--build-arg=OPENWRT_CONFIG=diffconfig.r5s.final \
	"--build-arg=RELEASE_VERSION=00000000-0000" \
	-t openwrt:r5s .

docker cp "$(docker create --rm openwrt:r5s):/out" ./