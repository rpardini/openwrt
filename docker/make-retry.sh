#!/usr/bin/env bash

# Runs `make <args>` in parallel; if that fails, shows the tails of the failing package logs and
# retries with -j1 V=s so the real error is in the output. Shared by the Dockerfile and 000.dev.sh.
#
# Usage: docker/make-retry.sh [make args...]

set -o errexit -o pipefail -o nounset

declare make_log
make_log="$(mktemp)"
trap 'rm -f "${make_log}"' EXIT

if make -j"$(($(nproc) + 2))" "$@" 2>&1 | tee "${make_log}"; then
	exit 0
fi

echo "=== parallel 'make $*' failed; tails of the failing package logs ==="
# make prints "ERROR: package/feeds/packages/libpfring failed to build." for each failed package;
# per-package logs are in logs/ (CONFIG_BUILD_LOG=y), under a path containing the package name.
declare failed_pkg pkg_name log_file found_any=0
while read -r failed_pkg; do
	pkg_name="$(basename "${failed_pkg}")"
	while read -r log_file; do
		found_any=1
		echo "--- ${log_file}"
		tail -n 60 "${log_file}"
	done < <(find logs -path "*/${pkg_name}/*" -name '*.txt' 2> /dev/null | head -5)
done < <(grep -oE 'ERROR: [^ ]+ failed to build' "${make_log}" | awk '{print $2}' | sort -u)

if [[ ${found_any} -eq 0 ]]; then
	echo "(no per-package logs found for the failed packages; falling back to a scan of logs/)"
	find logs -name '*.txt' -exec grep -l -E 'Error [0-9]+$|error:|Patch failed' {} + 2> /dev/null | head -20 | while read -r log_file; do
		echo "--- ${log_file}"
		tail -n 60 "${log_file}"
	done || true
fi

echo "=== retrying 'make $*' with -j1 V=s ==="
exec make -j1 V=s "$@"
