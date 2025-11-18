#!/usr/bin/env bash

docker buildx build \
	--progress=plain \
	--build-arg=OPENWRT_CONFIG=diffconfig.r5s.final \
	-t openwrt:r5s .

