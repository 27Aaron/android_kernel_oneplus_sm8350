#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rebuild vendor_dlkm.img for lemonadep: keep everything the ROM ships
# (etc/build.prop, fs_config, NOTICE, modules.blocklist) but replace every
# kernel module with the ones built from our kernel tree.
#
# The ROM's vendor modules were built against Infinity-X's own kernel tree,
# which has diverged from LineageOS (2852 of 5169 imported symbol CRCs differ),
# so they are refused by a LineageOS-derived kernel.  Replacing them keeps the
# kernel and its modules consistent.
#
# Usage:
#   repack-vendor-dlkm.sh <base/vendor_dlkm.img> <our .ko dir> <out.img> [release]
#
set -euo pipefail

BASE_IMG=$1
OUR_MODS=$2
OUT_IMG=$3
REL=${4:-5.4.302-qgki-gb0634b416a64-dirty}

WORK=$(mktemp -d /tmp/vdlkm-repack.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
mkdir -p "$ROOT" "$(dirname "$OUT_IMG")"

echo "==> extracting base image"
fsck.erofs --extract="$ROOT" --overwrite "$BASE_IMG" >/dev/null
MODDIR="$ROOT/lib/modules"
BASE_KO=$(find "$MODDIR" -maxdepth 1 -name '*.ko' | wc -l)
echo "    base has $BASE_KO modules"

# modules the ROM deliberately does not load: everything that is neither in
# modules.load nor in modules.blocklist is left out of the new modules.load,
# exactly like the ROM's own build does.
declare -A LOAD_SET=()
while IFS= read -r entry; do
	[ -n "$entry" ] && LOAD_SET["$entry"]=1
done < "$MODDIR/modules.load"

declare -A BLOCK_SET=()
while read -r _ mod; do
	[ -n "${mod:-}" ] && BLOCK_SET["$mod"]=1
done < <(grep '^blocklist ' "$MODDIR/modules.blocklist" || true)

declare -A EXCLUDE_SET=()
EXCLUDED_NAMES=""
for ko in "$MODDIR"/*.ko; do
	name=$(basename "$ko" .ko)
	if [ -z "${LOAD_SET[$name]+x}" ] && [ -z "${BLOCK_SET[$name]+x}" ]; then
		EXCLUDE_SET["$name"]=1
		EXCLUDED_NAMES="$EXCLUDED_NAMES $name"
	fi
done
echo "    excluded (not loaded by the ROM):${EXCLUDED_NAMES:- none}"

echo "==> replacing modules with our build"
rm -f "$MODDIR"/*.ko
find "$OUR_MODS" -type f -name '*.ko' -print0 |
	while IFS= read -r -d '' ko; do
		name=$(basename "$ko")
		# the ROM ships the qcacld driver as qca_cld3_wlan.ko
		[ "$name" = "wlan.ko" ] && name="qca_cld3_wlan.ko"
		cp -p "$ko" "$MODDIR/$name"
	done
NEW_KO=$(find "$MODDIR" -maxdepth 1 -name '*.ko' | wc -l)
echo "    copied $NEW_KO modules"

echo "==> depmod"
STAGING="$WORK/staging/lib/modules/$REL"
mkdir -p "$STAGING"
cp -p "$MODDIR"/*.ko "$STAGING/"
touch "$STAGING/modules.order" "$STAGING/modules.builtin" \
      "$STAGING/modules.builtin.modinfo"
depmod -a -b "$WORK/staging" "$REL"
for f in modules.alias modules.dep modules.softdep; do
	[ -f "$STAGING/$f" ] && cp -p "$STAGING/$f" "$MODDIR/$f"
done

# depmod writes paths like ../../lib/modules/<rel>/foo.ko; init looks them up
# relative to /vendor_dlkm
sed -i 's|[^ :]*lib/modules/[^/]*/||g' "$MODDIR/modules.dep"
sed -i 's|\([a-zA-Z0-9_.-]*\.ko\)|/vendor_dlkm/lib/modules/\1|g' "$MODDIR/modules.dep"

echo "==> regenerating modules.load"
: > "$MODDIR/modules.load"
for ko in "$MODDIR"/*.ko; do
	name=$(basename "$ko" .ko)
	if [ -z "${EXCLUDE_SET[$name]+x}" ] && [ -z "${BLOCK_SET[$name]+x}" ]; then
		echo "$name" >> "$MODDIR/modules.load"
	fi
done
wc -l < "$MODDIR/modules.load"

echo "==> building erofs image"
CTX="$WORK/file_contexts"
cat > "$CTX" <<'EOF'
/ u:object_r:vendor_file:s0
/vendor_dlkm(/.*)? u:object_r:vendor_file:s0
/vendor_dlkm/etc(/.*)? u:object_r:vendor_configs_file:s0
EOF

mkfs.erofs \
	--mount-point=/vendor_dlkm \
	--all-root \
	--file-contexts="$CTX" \
	-zlz4hc,12 -b4096 -T1230768000 \
	"$OUT_IMG" "$ROOT" >/dev/null

BASE_SIZE=$(stat -c %s "$BASE_IMG")
NEW_SIZE=$(stat -c %s "$OUT_IMG")
if [ "$NEW_SIZE" -le "$BASE_SIZE" ]; then
	echo "    padding $NEW_SIZE -> $BASE_SIZE bytes"
	truncate -s "$BASE_SIZE" "$OUT_IMG"
else
	echo "    WARNING: image is $NEW_SIZE bytes, larger than the ROM's $BASE_SIZE"
	echo "    (fastbootd can resize the logical partition, but check free space in super)"
fi

fsck.erofs "$OUT_IMG" >/dev/null && echo "    fsck.erofs: OK"
echo "==> done: $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
