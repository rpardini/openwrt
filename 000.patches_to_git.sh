#!/usr/bin/env bash
# apply-owrt-kernel-patches.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC_DIR" || exit 2

OPENWRT_DIR="${OPENWRT_DIR:-$SRC_DIR}"
KDIR="${KDIR:-/Volumes/LinuxDev/mainline-kernel}"        # your existing v6.18.44 tree
TARGET="${TARGET:-rockchip}"
SUBTARGET="${SUBTARGET:-}"              # only set if target/linux/$TARGET/$SUBTARGET/patches-$KVER exists
KVER="${KVER:-6.18}"

pick_dir() {  # base path without -$KVER suffix
  local versioned="${1}-${KVER}" plain="$1"
  [ -d "$versioned" ] && { echo "$versioned"; return; }
  [ -d "$plain" ] && { echo "$plain"; return; }
  echo ""
}

GENERIC="$OPENWRT_DIR/target/linux/generic"
PATCHDIRS=(
  "$(pick_dir "$GENERIC/backport")"
  "$(pick_dir "$GENERIC/pending")"
  "$(pick_dir "$GENERIC/hack")"
  "$(pick_dir "$OPENWRT_DIR/target/linux/$TARGET/patches")"
)
[ -n "$SUBTARGET" ] && PATCHDIRS+=("$(pick_dir "$OPENWRT_DIR/target/linux/$TARGET/$SUBTARGET/patches")")

cd "$KDIR"
git rev-parse --verify HEAD >/dev/null    # sanity: must already be a repo at the right base

for d in "${PATCHDIRS[@]}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  label="${d#"$OPENWRT_DIR"/target/linux/}"
  shopt -s nullglob
  for p in "$d"/*.patch; do
    echo "== $label/$(basename "$p")"
    if git am --keep-cr -q "$p" 2>/tmp/am.err; then
      continue
    fi
    echo "   git am failed, inspect /tmp/am.err — falling back to apply+commit"
    git am --abort 2>/dev/null || true
    git apply -p1 --index "$p"
    subj="$(grep -m1 '^Subject:' "$p" | sed -E 's/^Subject:\s*(\[PATCH[^]]*\]\s*)?//')"
    git commit -q -m "${subj:-$label/$(basename "$p")}" \
               -m "openwrt: $label/$(basename "$p")"
  done
  shopt -u nullglob
done

echo "Done: $(git rev-list --count HEAD ^v${KVER}.44) patch commits on top of v${KVER}.44."