#!/bin/sh
# Publish or update a GitHub release and refresh the version strings in the docs.
#   sh scripts/maintainer/release.sh <tag> <bin-dir> [patches-dir]
# <bin-dir>     OpenWrt bin/targets/airoha/an7563: the two BE5000 images,
#               version.buildinfo and the .manifest
# <patches-dir> output of `git format-patch` plus a diffconfig file (optional)
# Images live only in the release, never in git. Commit the doc changes afterwards.
set -eu

TAG=$1; BIN=$2; PATCHES=${3:-}
cd "$(dirname "$0")/../.."
SYS=openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin
RAM=openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin
VER=$(cat "$BIN/version.buildinfo")                                     # r36539+836-98bc30d154
KVER=$(sed -n 's/^kernel - \([0-9][0-9.]*\).*/\1/p' "$BIN"/*.manifest | head -1)
[ -n "$KVER" ] || { echo "kernel version not found in $BIN/*.manifest" >&2; exit 1; }

STAGE=$(mktemp -d)
cp "$BIN/$SYS" "$BIN/$RAM" "$STAGE/"
if [ -n "$PATCHES" ]; then
	tar czf "$STAGE/be5000-openwrt-source-patches.tar.gz" -C "$(dirname "$PATCHES")" "$(basename "$PATCHES")"
	cp "$PATCHES/diffconfig" "$STAGE/" 2>/dev/null || true
fi
(cd "$STAGE" && { command -v sha256sum >/dev/null 2>&1 && sha256sum -- * || shasum -a 256 -- *; } > SHA256SUMS)

# Version strings: short form in the READMEs, full form and tag in the image README.
sed -i.bak -E "s/r[0-9]+\+[0-9]+/${VER%%-*}/g; s/Linux [0-9]+\.[0-9]+\.[0-9]+/Linux $KVER/g" README.md README.ru.md
sed -i.bak -E "s/r[0-9]+\+[0-9]+-[0-9a-f]+/$VER/g; s/Linux [0-9]+\.[0-9]+\.[0-9]+/Linux $KVER/g; s#releases/tag/[^)]*#releases/tag/$TAG#g" firmware/openwrt/README.md
rm -f README.md.bak README.ru.md.bak firmware/openwrt/README.md.bak

if gh release view "$TAG" >/dev/null 2>&1; then
	gh release upload "$TAG" --clobber "$STAGE"/*
else
	gh release create "$TAG" --title "OpenWrt for BE5000 ($VER)" \
		--notes "OpenWrt $VER, Linux $KVER. What is inside: firmware/openwrt/README.md. Sources: branch be5000-main of https://github.com/pabragin/openwrt" "$STAGE"/*
fi
rm -rf "$STAGE"
echo "Release $TAG updated. Now review and commit: git diff README.md README.ru.md firmware/openwrt/README.md"
