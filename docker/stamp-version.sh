#!/usr/bin/env bash

# There is no .git in the build tree (see .dockerignore), so getver.sh would yield REVISION=unknown and
# get_source_date_epoch.sh would fall back to the current time. That makes base-files' version
# "<commitcount>~unknown", which apk rejects: the field after '~' must be a hex commit hash.
# Both scripts check these file overrides before trying git, so hand them values here.
#
# These are deliberately CONSTANT, not derived from git: the Dockerfile runs this in front of the toolchain,
# kernel and package builds, so a value that moved with every commit would invalidate all of them.
# The tail after the '-' is what ends up in the apk version, so it must be hex digits.
# CI can override both with real values (`./scripts/getver.sh`, `./scripts/get_source_date_epoch.sh`)
# when it wants an image that identifies its own source revision.
#
# Usage (in the tree root): OPENWRT_REVISION=r0-c0ffee OPENWRT_SOURCE_DATE_EPOCH=1767225600 docker/stamp-version.sh

set -o errexit -o pipefail -o nounset

declare revision="${OPENWRT_REVISION-r0-c0ffee}"
declare source_date_epoch="${OPENWRT_SOURCE_DATE_EPOCH-1767225600}"

[[ -n "${revision}" ]] || { echo "OPENWRT_REVISION is empty" >&2; exit 1; }
[[ -n "${source_date_epoch}" ]] || { echo "OPENWRT_SOURCE_DATE_EPOCH is empty" >&2; exit 1; }
echo "${revision}" > version
echo "${source_date_epoch}" > version.date
echo "REVISION: $(./scripts/getver.sh)"
echo "SOURCE_DATE_EPOCH: $(./scripts/get_source_date_epoch.sh)"
