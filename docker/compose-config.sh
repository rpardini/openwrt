#!/usr/bin/env bash

# Prints the diffconfig for <board> on stdout: the base config (diffconfig.r5s.final, a full diffconfig)
# with diffconfig.<board>.delta applied on top. A delta only holds what differs from the base - typically
# just the CONFIG_TARGET_..._DEVICE_ line - so boards don't each carry (and drift as) a full copy.
#   - any key the delta sets replaces the base's line for that key
#   - a delta that selects a device drops the base's device selection first
# For r5s (the base itself) the base is printed as-is. Shared by the Dockerfile, build-image.sh and 000.dev.sh.
#
# Usage: docker/compose-config.sh <board>      (DIFFCONFIG_BASE overrides the base file name)

set -o errexit -o pipefail -o nounset

declare board="${1:?usage: compose-config.sh <board>}"
declare base="${DIFFCONFIG_BASE:-diffconfig.r5s.final}"
declare delta="diffconfig.${board}.delta"

[[ -f "${base}" ]] || { echo "compose-config.sh: base config ${base} not found" >&2; exit 1; }

if [[ "${board}" == "r5s" && ! -f "${delta}" ]]; then
	cat "${base}"
	exit 0
fi

[[ -f "${delta}" ]] || { echo "compose-config.sh: no ${delta} for board '${board}'" >&2; exit 1; }

awk '
	function key(line) {
		if (match(line, /^CONFIG_[A-Za-z0-9_+.-]+=/)) return substr(line, 1, RLENGTH - 1)
		if (match(line, /^# CONFIG_[A-Za-z0-9_+.-]+ is not set$/)) return substr(line, 3, RLENGTH - 15)
		return ""
	}
	NR == FNR { k = key($0); if (k != "") { drop[k] = 1; if (k ~ /^CONFIG_TARGET_.*_DEVICE_/) drop_devices = 1 } next }
	{ k = key($0); if (k in drop) next; if (drop_devices && k ~ /^CONFIG_TARGET_.*_DEVICE_/) next; print }
' "${delta}" "${base}"
cat "${delta}"
