FROM debian:stable AS configured

# Install dependencies for building OpenWRT, plus utils for compression and randomizing MBR label-id
ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt -y install build-essential git make tree unzip wget file curl gawk python3 python3-dev rsync \
                                    libncurses5-dev python3-pyelftools python3-setuptools swig golang-go \
                                    fdisk zstd

# Use a regular user for building, as OpenWRT can't be built as root
RUN useradd -m openwrt && mkdir -p /src /dist && chown -R openwrt /src /dist
USER openwrt

WORKDIR /src/openwrt
COPY --chown=openwrt:root config config
COPY --chown=openwrt:root files files
COPY --chown=openwrt:root include include
COPY --chown=openwrt:root LICENSES LICENSES
COPY --chown=openwrt:root package package
COPY --chown=openwrt:root scripts scripts
COPY --chown=openwrt:root target target
COPY --chown=openwrt:root toolchain toolchain
COPY --chown=openwrt:root tools tools
COPY --chown=openwrt:root .gitattributes .gitignore BSDmakefile Config.in COPYING feeds.conf.default ./
COPY --chown=openwrt:root Makefile rules.mk ./
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

## # we don't ship packages, only the image (immutable firmware)
## # Use sed to turn all modules (CONFIG_xxx=m) into disabled "# CONFIG_xxx is not set"
## RUN grep '=m' .config || true
## RUN sed -i 's/^\(CONFIG_.*\)=m$/# \1 is not set/g' .config
## RUN make defconfig
## RUN ./scripts/diffconfig.sh > ${OPENWRT_CONFIG}.new
## RUN echo "Diff between provided config and final config used for build:"
## RUN diff -u ${OPENWRT_CONFIG} ${OPENWRT_CONFIG}.new || true

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
# Now lets build parts of OpenWRT, we can't build everything in one go as caches would grow too big.
# For each step, first do a parallel build with multiple cores; if it fails, build with -j1 V=s to get more verbose output so we know what broke in the GHA logs.

# Build the toolchain
RUN make -j$(($(nproc)+2)) toolchain/install || make toolchain/install -j1 V=s

# Build the kernel
RUN make -j$(($(nproc)+2)) target/linux/compile || make target/linux/compile -j1 V=s

# Build the packages
RUN make -j$(($(nproc)+2)) package/compile || make -j8 package/compile  || make -j4 package/compile || make -j2 package/compile || make package/compile -j1 V=s

# Build the firmware
RUN make -j$(($(nproc)+2)) || make -j1 V=s

# Show results with tree
# RUN tree -h  bin

# Show results with du
# RUN du -h -d 6 -x bin | sort -h

# Decompress gzip, random MBR label-id, and compress with zstd
RUN cp -v bin/targets/*/*/*.img.gz /dist && \
    ls -lah /dist/*.img.gz && \
    gunzip /dist/*.img.gz || true && \
    echo 'before: ' && sfdisk -d /dist/*.img && \
    LABEL_ID="$(bash -c 'echo $(( RANDOM * 32768 + RANDOM ))')" && echo "random: $LABEL_ID" && \
    sfdisk --disk-id /dist/*.img "${LABEL_ID}" && \
    echo 'after:' && sfdisk -d /dist/*.img && \
    zstdmt -9 --rm /dist/*.img && ls -lah /dist/*.img*

ARG RELEASE_VERSION="00000000-0000"

# If packages present, pack them into a tarball and ship them to /dist as well
RUN <<HEREDOC
# Packages will be in bin/targets/rockchip/armv8/packages - but the whole bin/targets/rockchip/armv8 (minus the .img.gz) is interesting to have
# Grab the name of the image (resolve glob bin/targets/*/*/*.img.gz)
image_name_full_base="$(basename $(ls bin/targets/*/*/*.img.gz | head -n1) .img.gz)"
# remove the trailing -ext4-sysupgrade if present
extras_name=${image_name_full_base%-ext4-sysupgrade}-extras-${RELEASE_VERSION}
echo "Extras name: '${extras_name}'"
rm -rfv bin/targets/*/*/*.img.gz bin/targets/*/*/kernel-debug.tar.zst # drop the image and debug files
# Pack the rest into a tarball in /dist/${extras_name}-extra.tar.zst, with an intermediate dir also with extras_name
tar -cf - -C bin/targets/rockchip/armv8 --transform "s|^|${extras_name}/|" . | zstdmt -9 -o /dist/${extras_name}.tar.zst
ls -lah /dist/${extras_name}.tar.zst
# list the contents of tarball
#tar -tvf /dist/${extras_name}.tar.zst

# Since we're here also rename the image output to contain the -${RELEASE_VERSION}
mv /dist/${image_name_full_base}.img.zst /dist/${image_name_full_base}-${RELEASE_VERSION}.img.zst

ls -lah /dist
HEREDOC

# Finally the output stage
FROM alpine:3
WORKDIR /out
COPY --from=build /dist/* /out/
