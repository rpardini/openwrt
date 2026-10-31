#!/usr/bin/env bash

# Incremental dev builds. 000.build.sh rebuilds everything whenever anything under package/ or target/ changes
# (Docker layer cache); this keeps the whole build tree in a persistent container + volume instead, syncs
# the repo's sources into it, and lets make rebuild only what actually changed.
# The build steps themselves are the same docker/*.sh scripts the Dockerfile runs, so dev and CI don't drift.
# 000.build.sh stays the clean, CI-equivalent full build: use it for a final check.
#
# Usage:
#   ./000.dev.sh up                           # once: build base image (feeds+dl), create volume + container
#   ./000.dev.sh build                        # sync + toolchain, kernel, packages, firmware (incremental)
#   ./000.dev.sh make <make args...>          # sync + make, e.g. package/boot/uboot-rockchip/{clean,compile} V=s
#   ./000.dev.sh image <board> <custom|generic>  # sync + docker/build-image.sh; result in ./out/dev
#   ./000.dev.sh sync | shell | logs <pkg> | reset
#
# Output is also teed to logs-dev-<command>-<timestamp>.txt (logs-dev-latest.txt = newest); `shell` is not logged.
# DEV_BOARD (default r5s) picks diffconfig.<board>.final as the tree's .config; it's re-applied when that file changes.

set -o errexit -o pipefail -o nounset

declare SRC_DIR
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SRC_DIR}"

# Everything but the interactive shell is also teed to ./logs-dev-<command>-<timestamp>.txt (gitignored via /logs-*.txt),
# with logs-dev-latest.txt pointing at the newest one. Re-exec'd through tee so the exit status is the command's own.
if [[ -z "${DEV_LOGGING:-}" && "${1:-}" != "shell" ]]; then
	declare logfile="logs-dev-${1:-help}-$(date +%Y%m%d-%H%M%S).txt"
	ln -sf "${logfile}" logs-dev-latest.txt
	echo "==> logging to ${logfile}"
	DEV_LOGGING=1 "${BASH_SOURCE[0]}" "$@" 2>&1 | tee "${logfile}"
	exit "${PIPESTATUS[0]}"
fi

declare -r builder="openwrt-unlimited-logs" # see 000.build.sh
declare -r base_image="openwrt-dev-base"
declare -r container="openwrt-dev"
declare -r volume="openwrt-dev-tree"
declare -r board="${DEV_BOARD:-r5s}"
declare -r tree="/src/openwrt"

function die() {
	echo "000.dev.sh: $*" >&2
	exit 1
}

function in_container() { # runs a command in the build tree as the build user
	local -a tty=(-i)
	[[ -t 0 && -t 1 ]] && tty=(-it)
	docker exec "${tty[@]}" -u openwrt -w "${tree}" "${container}" "$@"
}

function ensure_running() {
	docker container inspect "${container}" > /dev/null 2>&1 || die "no container; run './000.dev.sh up' first"
	[[ "$(docker container inspect -f '{{.State.Running}}' "${container}")" == "true" ]] || docker start "${container}" > /dev/null
}

function do_up() {
	if ! docker buildx inspect "${builder}" > /dev/null 2>&1; then
		docker buildx create --name "${builder}" --driver docker-container \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=-1 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=-1
	fi
	docker buildx build --builder "${builder}" --load --progress=plain --target downloaded \
		--build-arg="MACHINE_ID=${board}" "--build-arg=OPENWRT_CONFIG=diffconfig.${board}.final" \
		--build-arg="RELEASE_VERSION=00000000-0000" -t "${base_image}" .

	if ! docker container inspect "${container}" > /dev/null 2>&1; then
		# a new named volume is seeded from the image's content at the mount point: feeds, dl, .config
		docker volume create "${volume}" > /dev/null
		docker run -d --name "${container}" -u openwrt -w "${tree}" \
			-v "${volume}:${tree}" -v "${SRC_DIR}:/host-src:ro" "${base_image}" sleep infinity > /dev/null
	fi
	ensure_running
	do_sync
	in_container bash docker/stamp-version.sh
	in_container bash docker/patch-python-host.sh
	echo "==> ready; try './000.dev.sh build'"
}

function do_sync() {
	ensure_running
	# Sources owned by the repo are mirrored (mtimes kept, so make only sees real changes). Everything the build
	# creates (build_dir, staging_dir, bin, logs, tmp, dl, feeds, package/feeds, scripts/config objects) is left alone.
	in_container bash -s "${board}" << 'SYNC'
set -o errexit -o nounset
for d in target toolchain tools include config docker; do
	rsync -a --delete "/host-src/${d}/" "${d}/"
done
rsync -a --delete --exclude=/feeds /host-src/package/ package/
rsync -a /host-src/scripts/ scripts/
for d in /host-src/files_*; do rsync -a --delete "${d}/" "$(basename "${d}")/"; done
rsync -a /host-src/Config.in /host-src/Makefile /host-src/rules.mk .
rsync -a /host-src/diffconfig.*.final .

# re-seed .config only when this board's diffconfig changed (or build-image.sh replaced .config)
board="${1}"
want="$(sha256sum "diffconfig.${board}.final" | cut -d' ' -f1)"
if [[ "$(cat .dev-diffconfig.sha256 2> /dev/null || true)" != "${want}" ]]; then
	echo "==> seeding .config from diffconfig.${board}.final"
	cp "diffconfig.${board}.final" .config
	make defconfig
	echo "${want}" > .dev-diffconfig.sha256
fi
SYNC
}

function do_build() {
	do_sync
	in_container bash docker/make-retry.sh toolchain/install
	in_container bash docker/make-retry.sh target/linux/compile
	in_container bash docker/make-retry.sh package/compile
	in_container bash docker/make-retry.sh
}

function do_image() {
	local img_board="${1:?usage: image <board> <custom|generic>}" variant="${2:?usage: image <board> <custom|generic>}"
	do_sync
	in_container bash docker/build-image.sh "${img_board}" "${variant}" "dev-$(date -u +%Y%m%d-%H%M)" --extras
	in_container rm -f .dev-diffconfig.sha256 # build-image.sh replaced .config; re-seed on next sync
	mkdir -p out/dev
	docker cp "${container}:/dist/." out/dev/
	ls -lah out/dev
}

case "${1:-}" in
	up) do_up ;;
	sync) do_sync ;;
	build) do_build ;;
	make) shift && do_sync && in_container make "$@" ;;
	image) shift && do_image "$@" ;;
	shell) ensure_running && in_container bash ;;
	logs)
		ensure_running
		in_container bash -c 'find logs -path "*/$1/*" -name "*.txt" -exec tail -n 80 {} +' _ "${2:?usage: logs <package-name>}"
		;;
	reset)
		docker rm -f "${container}" > /dev/null 2>&1 || true
		docker volume rm "${volume}" > /dev/null 2>&1 || true
		echo "==> removed ${container} and ${volume}"
		;;
	*) die "usage: $0 up|sync|build|make <args>|image <board> <variant>|shell|logs <pkg>|reset" ;;
esac
