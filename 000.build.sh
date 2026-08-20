#!/usr/bin/env bash

set -e

declare target="${1:-"r5s"}"

# The image has no .git, so resolve these here and pass them in; see the build stage in Dockerfile.
declare openwrt_revision openwrt_source_date_epoch
openwrt_revision="$(./scripts/getver.sh)"
openwrt_source_date_epoch="$(./scripts/get_source_date_epoch.sh)"
echo "REVISION: ${openwrt_revision} SOURCE_DATE_EPOCH: ${openwrt_source_date_epoch}"

docker buildx build \
	--progress=plain \
	--build-arg="MACHINE_ID=${target}" \
	"--build-arg=OPENWRT_CONFIG=diffconfig.${target}.final" \
	"--build-arg=RELEASE_VERSION=00000000-0000" \
	"--build-arg=OPENWRT_REVISION=${openwrt_revision}" \
	"--build-arg=OPENWRT_SOURCE_DATE_EPOCH=${openwrt_source_date_epoch}" \
	-t openwrt:r5s .

docker cp "$(docker create --rm openwrt:r5s):/out" ./