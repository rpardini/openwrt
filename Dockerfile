FROM debian:stable AS configured

# Install dependencies for building OpenWRT, plus utils for compression and randomizing MBR label-id
ENV DEBIAN_FRONTEND=noninteractive

# Enable trixie-backports for golang-1.26
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/trixie-backports.list
RUN apt -y update && apt -y install build-essential git make tree unzip wget file curl gawk python3 python3-dev rsync \
                                    libncurses5-dev python3-pyelftools python3-setuptools swig golang-1.26 \
                                    fdisk zstd

# Use a regular user for building, as OpenWRT can't be built as root
RUN useradd -m openwrt && mkdir -p /src /dist && chown -R openwrt /src /dist
USER openwrt

WORKDIR /src/openwrt
COPY --chown=openwrt:root config config
COPY --chown=openwrt:root include include
COPY --chown=openwrt:root LICENSES LICENSES
COPY --chown=openwrt:root package package
COPY --chown=openwrt:root scripts scripts
COPY --chown=openwrt:root target target
COPY --chown=openwrt:root toolchain toolchain
COPY --chown=openwrt:root tools tools
COPY --chown=openwrt:root .gitattributes .gitignore BSDmakefile Config.in COPYING feeds.conf.default ./
COPY --chown=openwrt:root Makefile rules.mk ./

# Add the configuration files to be included in the image
ARG MACHINE_ID="r5s"
COPY --chown=openwrt:root files_${MACHINE_ID} files
RUN ls -lah

RUN <<HEREDOC
echo "Fix feeds.conf.default to use GitHub instead of git.openwrt.org - pre pull"
sed -i 's|git.openwrt.org/project/|github.com/openwrt/|g' ./feeds.conf.default
sed -i 's|git.openwrt.org/feed/|github.com/openwrt/|g' ./feeds.conf.default
HEREDOC

# Show contents of cache
RUN --mount=type=cache,id=openwrt_feeds,target=/src/openwrt/feeds,uid=1000 du -h -d 3 -x /src/openwrt/feeds | sort -h
# Update and install feeds; use cache for feeds
RUN --mount=type=cache,id=openwrt_feeds,target=/src/openwrt/feeds,uid=1000 ./scripts/feeds update -a && ./scripts/feeds install -a && cp -pr /src/openwrt/feeds /src/openwrt/feeds_cached
# Copy back the cached feeds
RUN rm -rf /src/openwrt/feeds && mv /src/openwrt/feeds_cached /src/openwrt/feeds

# Use GitHub for feeds; don't use git.openwrt.org
RUN <<HEREDOC
cat ./feeds.conf.default
(cd feeds/packages && git status && git remote -v)
(cd feeds/luci && git status && git remote -v)
(cd feeds/routing && git status && git remote -v)
(cd feeds/telephony && git status && git remote -v)
HEREDOC

ARG OPENWRT_CONFIG=diffconfig.r5s.final
ADD --chown=openwrt:root ${OPENWRT_CONFIG} ./
RUN cp -v ${OPENWRT_CONFIG} .config
RUN make defconfig

ARG RELEASE_VERSION="00000000-0000"
# In include/version.mk, replace all occurences of the string "SNAPSHOT" with "yy.mm-${RELEASE_VERSION}"
RUN <<HEREDOC
cp -v include/version.mk include/version.mk.orig
YEAR_2_DIGITS=$(date +%y)
MONTH_2_DIGITS=$(date +%m)
echo "Setting release version to ${YEAR_2_DIGITS}.${MONTH_2_DIGITS}-${RELEASE_VERSION} in include/version.mk"
sed -i "s/SNAPSHOT/${YEAR_2_DIGITS}.${MONTH_2_DIGITS}-${RELEASE_VERSION}/g" ./include/version.mk || true # do NOT fail
diff -u include/version.mk.orig include/version.mk || true # do NOT fail
rm include/version.mk.orig
HEREDOC

FROM configured AS downloaded

RUN id openwrt

# Show contents of dl cache
RUN --mount=type=cache,id=openwrt_dl,target=/src/openwrt/dl,uid=1000 du -h -d 3 -x /src/openwrt/dl | sort -h

# Download sources; as this can fail due to network issues, we retry a few times with decreasing parallelism
RUN --mount=type=cache,id=openwrt_dl,target=/src/openwrt/dl,uid=1000 { make download -j$(($(nproc)+2)) || make download -j4 || make download -j2 || make download || make download -j1 V=s; } && cp -pr /src/openwrt/dl /src/openwrt/dl_cached
# Show sizes
RUN du -h -d 3 -x . | sort -h
# Move
RUN rm -rf /src/openwrt/dl && mv /src/openwrt/dl_cached /src/openwrt/dl
# Show sizes
RUN du -h -d 3 -x . | sort -h

FROM downloaded AS build

# There is no .git in the image (see .dockerignore); docker/stamp-version.sh hands getver.sh and
# get_source_date_epoch.sh constant values instead, see the comments there.
ARG OPENWRT_REVISION="r0-c0ffee"
ARG OPENWRT_SOURCE_DATE_EPOCH="1767225600"
RUN --mount=type=bind,source=docker/stamp-version.sh,target=/tmp/stamp-version.sh bash /tmp/stamp-version.sh

# Now lets build parts of OpenWRT, we can't build everything in one go as caches would grow too big.
# For each step, docker/make-retry.sh does a parallel build with multiple cores; if it fails, it shows the failing package logs and
# builds with -j1 V=s to get more verbose output so we know what broke in the GHA logs. The same scripts are used by 000.dev.sh.
# Each script is bind-mounted into its own step, so editing one only invalidates the steps that use it.

# Build the toolchain
RUN --mount=type=bind,source=docker/make-retry.sh,target=/tmp/make-retry.sh bash /tmp/make-retry.sh toolchain/install

# Build the kernel
RUN --mount=type=bind,source=docker/make-retry.sh,target=/tmp/make-retry.sh bash /tmp/make-retry.sh target/linux/compile

# Work around a python3 host-build breakage in the packages feed (see docker/patch-python-host.sh).
# Kept here, and not next to the feeds install, on purpose: this layer sits after the toolchain and
# kernel builds, so applying it does not invalidate those (expensive) cached layers.
RUN --mount=type=bind,source=docker/patch-python-host.sh,target=/tmp/patch-python-host.sh bash /tmp/patch-python-host.sh

# Build the packages
RUN --mount=type=bind,source=docker/make-retry.sh,target=/tmp/make-retry.sh bash /tmp/make-retry.sh package/compile

# Build the firmware
RUN --mount=type=bind,source=docker/make-retry.sh,target=/tmp/make-retry.sh bash /tmp/make-retry.sh

# Show results with tree
# RUN tree -h  bin

# Show results with du
# RUN du -h -d 6 -x bin | sort -h

### --------------------------------------------------------------------------------------------------------------------
### Per-board image stages. Everything above this line is board-agnostic: all boards are rockchip/armv8 (r6c is disabled for now), so they
### share the same toolchain, kernel and packages, and their diffconfigs differ only in the selected device. Each stage below
### just re-points .config at its board, swaps the files/ overlay and re-runs the image build; they do not depend on each other, so buildx builds them in parallel.
###
### Two variants per board:
###   custom  - files_<board> overlaid: rpardini's authorized_keys, frr/dnsmasq/rc.local config, ...
###   generic - no files/ overlay at all, for anyone else's use
###
### The extras tarball only comes out of the custom stages: its contents do not depend on the files/ overlay, so
### shipping one per variant would just double the upload. Append --extras to a generic stage to get one anyway.
### --------------------------------------------------------------------------------------------------------------------

FROM build AS image-common
COPY --chown=openwrt:root docker/build-image.sh docker/make-retry.sh docker/
COPY --chown=openwrt:root diffconfig.r5s.final ./
COPY --chown=openwrt:root files_r5s files_r5s

FROM image-common AS image-r5s-custom
ARG RELEASE_VERSION="00000000-0000"
RUN ./docker/build-image.sh r5s custom "${RELEASE_VERSION}" --extras

FROM image-common AS image-r5s-generic
ARG RELEASE_VERSION="00000000-0000"
RUN ./docker/build-image.sh r5s generic "${RELEASE_VERSION}"

# Finally the output stage, collecting what every board/variant stage shipped to /dist
FROM alpine:3
WORKDIR /out
COPY --from=image-r5s-custom /dist/ /out/
COPY --from=image-r5s-generic /dist/ /out/
