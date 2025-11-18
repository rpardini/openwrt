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

#RUN <<HEREDOC
#echo "Fix feeds.conf.default to use GitHub instead of git.openwrt.org - pre pull"
#sed -i 's|git.openwrt.org/feed/|github.com/openwrt/|g' ./feeds.conf.default
#HEREDOC

RUN ./scripts/feeds update -a && ./scripts/feeds install -a

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

RUN grep '=m' .config

# Use sed to turn all modules (=m) into built-in (=y) - we don't ship packages, only the image (immutable firmware)
RUN sed -i 's/=\(m\)/=y/g' .config
RUN make defconfig

RUN ./scripts/diffconfig.sh > ${OPENWRT_CONFIG}.new

RUN echo "Diff between provided config and final config used for build:"
RUN diff -u ${OPENWRT_CONFIG} ${OPENWRT_CONFIG}.new || true

FROM configured AS build
# Download sources; as this can fail due to network issues, we retry a few times with decreasing parallelism
RUN make download -j$(($(nproc)+2)) || make download -j4 || make download -j2 || make download || make download

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
RUN tree -h bin

# Decompress gzip, random MBR label-id, and compress with zstd
RUN cp -v bin/targets/*/*/*.img.gz /dist && \
    ls -lah /dist/*.img.gz && \
    gunzip /dist/*.img.gz || true && \
    echo 'before: ' && sfdisk -d /dist/*.img && \
    LABEL_ID="$(bash -c 'echo $(( RANDOM * 32768 + RANDOM ))')" && echo "random: $LABEL_ID" && \
    sfdisk --disk-id /dist/*.img "${LABEL_ID}" && \
    echo 'after:' && sfdisk -d /dist/*.img && \
    zstdmt --rm /dist/*.img && ls -lah /dist/*.img*

# Finally the output stage
FROM alpine:3
WORKDIR /out
COPY --from=build /dist/* /out/
