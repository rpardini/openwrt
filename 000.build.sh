#!/usr/bin/env bash

set -e

declare target="${1:-"r5s"}"

# The image has no .git, so REVISION/SOURCE_DATE_EPOCH are handed in; see the build stage in Dockerfile.
# Keep these CONSTANT: they sit in front of the toolchain/kernel/package layers, so deriving them from
# git would throw away the whole build cache on every commit. The tail after the '-' must be hex digits.
# For an image that identifies its real source revision, override with:
#   openwrt_revision="$(./scripts/getver.sh)"
#   openwrt_source_date_epoch="$(./scripts/get_source_date_epoch.sh)"
declare openwrt_revision="${OPENWRT_REVISION:-"r0-c0ffee"}"
declare openwrt_source_date_epoch="${OPENWRT_SOURCE_DATE_EPOCH:-"1767225600"}"
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