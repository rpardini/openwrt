#!/usr/bin/env bash

declare REMOTE_SHA1 LOCAL_SHA1
REMOTE_SHA1=$(git ls-remote "https://github.com/rpardini/openwrt.git" "r5s" | awk '{ print $1 }')
LOCAL_SHA1=$(git rev-parse HEAD)

if [ "$REMOTE_SHA1" != "$LOCAL_SHA1" ]; then
	echo "Remote SHA1 ($REMOTE_SHA1) does not match local SHA1 ($LOCAL_SHA1). Please update your local repository or push your stuff."
	exit 1
fi

docker build \
	--progress=plain \
	--build-arg=OPENWRT_GIT_URL=https://github.com/rpardini/openwrt.git --build-arg=OPENWRT_BRANCH=r5s \
	"--build-arg=OPENWRT_REVISION=$REMOTE_SHA1" --build-arg=OPENWRT_CONFIG=diffconfig.r5s.final \
	-t openwrt:r5s .
