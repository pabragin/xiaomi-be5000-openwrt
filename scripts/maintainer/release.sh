#!/bin/sh
# Publish or update a GitHub release and refresh the version strings in the docs.
#   sh scripts/maintainer/release.sh <tag> <bin-dir> [patches-dir]
# <bin-dir>     OpenWrt bin/targets/airoha/an7563: the two BE5000 images,
#               version.buildinfo and the .manifest
# <patches-dir> output of `git format-patch` plus a diffconfig file (optional)
# Images live only in the release, never in git. Commit the doc changes afterwards.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 <tag> <bin-dir> [patches-dir]" >&2; exit 1; }
TAG=$1; BIN=$(cd "$2" && pwd); PATCHES=${3:+$(cd "$3" && pwd)}
cd "$(dirname "$0")/../.."
SYS=openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin
RAM=openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin
VER=$(cat "$BIN/version.buildinfo")                                     # r36539+836-98bc30d154
KVER=$(sed -n 's/^kernel - \([0-9][0-9.]*\).*/\1/p' "$BIN"/*.manifest | head -1)
[ -n "$KVER" ] || { echo "kernel version not found in $BIN/*.manifest" >&2; exit 1; }
MT76=$(sed -n 's/^kmod-mt76-core - .*\([0-9]\{4\}\)\.\([0-9]\{2\}\)\.\([0-9]\{2\}\)~.*/\1-\2-\3/p' "$BIN"/*.manifest | head -1)   # 2026-10-08
[ -n "$MT76" ] || echo "warning: mt76 version not found in the manifest, leaving it as is" >&2
MT76_SED=""
[ -n "$MT76" ] && MT76_SED="s/mt76 [0-9]{4}-[0-9]{2}-[0-9]{2}/mt76 $MT76/g;"

STAGE=$(mktemp -d)
cp "$BIN/$SYS" "$BIN/$RAM" "$STAGE/"
FILES="$SYS $RAM"
if [ -n "$PATCHES" ]; then
	tar czf "$STAGE/be5000-openwrt-source-patches.tar.gz" -C "$(dirname "$PATCHES")" "$(basename "$PATCHES")"
	FILES="$FILES be5000-openwrt-source-patches.tar.gz"
	[ -f "$PATCHES/diffconfig" ] && cp "$PATCHES/diffconfig" "$STAGE/" && FILES="$FILES diffconfig"
fi
if command -v sha256sum >/dev/null 2>&1; then SUM=sha256sum; else SUM="shasum -a 256"; fi
(cd "$STAGE" && $SUM $FILES > SHA256SUMS)

# Version strings: short form in the READMEs, full form and tag in the image README.
sed -i.bak -E "s/r[0-9]+\+[0-9]+/${VER%%-*}/g; s/Linux [0-9]+\.[0-9]+\.[0-9]+/Linux $KVER/g" README.md README.ru.md
sed -i.bak -E "s/r[0-9]+\+[0-9]+-[0-9a-f]+/$VER/g; s/Linux [0-9]+\.[0-9]+\.[0-9]+/Linux $KVER/g; ${MT76_SED} s#releases/tag/[^)]*#releases/tag/$TAG#g" firmware/openwrt/README.md
rm -f README.md.bak README.ru.md.bak firmware/openwrt/README.md.bak

if gh release view "$TAG" >/dev/null 2>&1; then
	gh release upload "$TAG" --clobber "$STAGE"/*
else
	gh release create "$TAG" --title "OpenWrt for BE5000 ($VER)" \
		--notes "OpenWrt $VER, Linux $KVER. What is inside: firmware/openwrt/README.md. Sources: branch be5000-main of https://github.com/pabragin/openwrt" "$STAGE"/*
fi
rm -rf "$STAGE"
echo "Release $TAG updated. Now review and commit: git diff README.md README.ru.md firmware/openwrt/README.md"
