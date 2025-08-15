#!/usr/bin/env bash

set -e
set -x

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC_DIR" || exit 2

LOCAL_FILES_DIR="$(pwd)/files"
LOCAL_FILES_ETC_DIR="$LOCAL_FILES_DIR/etc"

SOURCE_IP="192.168.66.1"


declare -a dirs_to_copy=("/etc/config" "/etc/dropbear" "/etc/nginx" "/etc/frr")

# Loop over the directories and copy them using scp from the SOURCE_IP

for dir in "${dirs_to_copy[@]}"; do
	echo "--> Copying $dir from $SOURCE_IP to $LOCAL_FILES_ETC_DIR"
	scp -r "root@$SOURCE_IP:$dir" "$LOCAL_FILES_ETC_DIR/" || true
done

echo "--> Done..."