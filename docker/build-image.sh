#!/usr/bin/env bash

# Builds one image variant, inside the build container, on top of the shared build stage.
# That stage has already compiled the toolchain, the kernel and every package for rockchip/armv8,
# and all three boards share those, so what actually runs here is the image assembly plus whatever
# handful of packages differ between the board configs.
#
# Usage: docker/build-image.sh <board> <custom|generic> <release_version> [--extras]

set -o errexit -o pipefail -o nounset

declare board="${1}"           # e24c | r5s | r6c; picks diffconfig.<board>.final and files_<board>
declare variant="${2}"         # custom: overlay files_<board>; generic: no overlay at all
declare release_version="${3}" # ends up in the names of the shipped files
declare extras="${4:-}"        # --extras: also pack up bin/targets into a tarball

declare target_dir="bin/targets/rockchip/armv8"
declare log_prefix="==> [${board}/${variant}]"

echo "${log_prefix} configuring"
cp -v "diffconfig.${board}.final" .config
make defconfig

# The files/ overlay the shared stage was seeded with is whatever board 000.build.sh was invoked
# for; replace it with this board's, or with nothing at all for the generic variant.
rm -rf files
case "${variant}" in
	custom)
		cp -a "files_${board}" files
		echo "${log_prefix} files/ overlay:"
		find files -type f | sort
		;;
	generic)
		echo "${log_prefix} no files/ overlay, this is the generic variant"
		;;
	*)
		echo "${log_prefix} unknown variant '${variant}', expected 'custom' or 'generic'" >&2
		exit 1
		;;
esac

# OpenWRT's stamps track the package sources, not .config's device selection nor the files/ overlay,
# so without this the rootfs and images from the shared stage's build would just be kept as-is.
rm -f staging_dir/target-*/stamp/.package_install staging_dir/target-*/stamp/.target_install

# Drop the shared stage's images, manifests and sha256sums so only this board's end up here - but
# keep packages/, whose .apk files are produced at package build time and would not be regenerated.
if [[ -d "${target_dir}" ]]; then
	find "${target_dir}" -maxdepth 1 -type f -delete
fi

echo "${log_prefix} building the image"
make -j"$(($(nproc) + 2))" || make -j1 V=s

# Device/Default in target/linux/rockchip/image/Makefile sets IMAGES := sysupgrade.img.gz, so with a
# single device selected there is exactly one image here. Anything else means this needs a look.
declare -a built_images=("${target_dir}"/*.img.gz)
if [[ ${#built_images[@]} -ne 1 ]]; then
	echo "${log_prefix} expected exactly one image in ${target_dir}, found: ${built_images[*]}" >&2
	exit 1
fi

declare image_name_base shipped_name
image_name_base="$(basename "${built_images[0]}" .img.gz)"
shipped_name="${image_name_base}-${release_version}-${variant}"

# Decompress gzip, random MBR label-id, and compress with zstd
echo "${log_prefix} shipping /dist/${shipped_name}.img.zst"
cp -v "${built_images[0]}" "/dist/${shipped_name}.img.gz"

# The images are built as "gzip | append-metadata", so the sysupgrade metadata sits after the gzip
# stream and gzip reports it as "trailing garbage ignored" - a warning, which is exit code 2. Only
# that one is tolerated here; a real decompression failure (exit code 1) still stops the build.
declare gunzip_status=0
gunzip "/dist/${shipped_name}.img.gz" || gunzip_status=$?
if [[ ${gunzip_status} -ne 0 && ${gunzip_status} -ne 2 ]]; then
	echo "${log_prefix} gunzip failed with exit code ${gunzip_status}" >&2
	exit "${gunzip_status}"
fi
echo 'before: ' && sfdisk -d "/dist/${shipped_name}.img"
declare label_id="$((RANDOM * 32768 + RANDOM))" && echo "random: ${label_id}"
sfdisk --disk-id "/dist/${shipped_name}.img" "${label_id}"
echo 'after:' && sfdisk -d "/dist/${shipped_name}.img"
zstdmt -9 --rm "/dist/${shipped_name}.img"

# Packages live in bin/targets/rockchip/armv8/packages - but the whole directory (minus the image
# and the debug files) is interesting to have, so pack it up and ship it as well.
if [[ "${extras}" == "--extras" ]]; then
	declare extras_name="${image_name_base%-ext4-sysupgrade}-extras-${release_version}"
	echo "${log_prefix} shipping /dist/${extras_name}.tar.zst"
	rm -rfv "${target_dir}"/*.img.gz "${target_dir}"/kernel-debug.tar.zst
	# ... with an intermediate dir also named after extras_name
	tar -cf - -C "${target_dir}" --transform "s|^|${extras_name}/|" . | zstdmt -9 -o "/dist/${extras_name}.tar.zst"
elif [[ -n "${extras}" ]]; then
	echo "${log_prefix} unknown option '${extras}', expected '--extras'" >&2
	exit 1
fi

ls -lah /dist
