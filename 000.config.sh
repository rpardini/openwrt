#!/usr/bin/env bash

declare REMOTE_SHA1 LOCAL_SHA1
REMOTE_SHA1=$(git ls-remote "https://github.com/rpardini/openwrt.git" "r5s" | awk '{ print $1 }')
LOCAL_SHA1=$(git rev-parse HEAD)

if [ "$REMOTE_SHA1" != "$LOCAL_SHA1" ]; then
	echo "Remote SHA1 ($REMOTE_SHA1) does not match local SHA1 ($LOCAL_SHA1). Please update your local repository or push your stuff."
	exit 1
fi

docker buildx build "--build-arg=OPENWRT_REVISION=$REMOTE_SHA1" --progress=plain -t openwrt:config --target configured .
docker run -it -v "$(pwd):/host" openwrt:config /bin/bash -c "cd /src/openwrt && make menuconfig && ./scripts/diffconfig.sh > /host/diffconfig.r5s.final && echo done"
