#!/usr/bin/env bash

set -e

declare target="${1:-"r5s"}"

# BuildKit clips each step's log at 2MiB by default ("log limit 2MiB reached"), hiding the failing part of a
# long OpenWrt build. The limit is read by the buildkitd daemon, not the client, so use a dedicated
# docker-container builder with the limits lifted (-1 = unlimited).
declare builder="openwrt-unlimited-logs"
if ! docker buildx inspect "${builder}" > /dev/null 2>&1; then
	docker buildx create --name "${builder}" --driver docker-container \
		--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=-1 \
		--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=-1
fi

docker buildx build \
	--builder "${builder}" \
	--load \
	--progress=plain \
	--build-arg="MACHINE_ID=${target}" \
	"--build-arg=OPENWRT_CONFIG=diffconfig.${target}.final" \
	"--build-arg=RELEASE_VERSION=00000000-0000" \
	-t openwrt:r5s .

docker cp "$(docker create --rm openwrt:r5s):/out" ./
