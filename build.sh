#!/bin/sh
# Build the USB/IP appliance SD card image for a Raspberry Pi 4 (64-bit).
#
#   ./build.sh                 # clone Buildroot if needed, configure, build
#   ./build.sh menuconfig      # any extra args are passed to make
#
# Environment:
#   BUILDROOT   path to a Buildroot tree   (default: ./buildroot)
#   BR_VERSION  tag to clone if missing    (default: 2026.02.3, LTS)
#   OUT         output directory           (default: ./output)
set -eu

EXT=$(cd "$(dirname "$0")" && pwd)
BUILDROOT=${BUILDROOT:-$EXT/buildroot}
BR_VERSION=${BR_VERSION:-2026.02.3}
OUT=${OUT:-$EXT/output}

if [ ! -d "$BUILDROOT" ]; then
    git clone --depth 1 -b "$BR_VERSION" \
        https://github.com/buildroot/buildroot.git "$BUILDROOT"
fi

mkdir -p "$OUT"
DEFCONFIG=$OUT/usbip_rpi4_defconfig
cat "$BUILDROOT/configs/raspberrypi4_64_defconfig" \
    "$EXT/configs/usbip_rpi4.fragment" > "$DEFCONFIG"

if [ ! -f "$OUT/.config" ] || [ "$DEFCONFIG" -nt "$OUT/.config" ]; then
    make -C "$BUILDROOT" O="$OUT" BR2_EXTERNAL="$EXT" \
        BR2_DEFCONFIG="$DEFCONFIG" defconfig
fi

make -C "$OUT" "$@"

if [ $# -eq 0 ]; then
    echo
    echo "Image: $OUT/images/sdcard.img"
fi
