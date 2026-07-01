#!/usr/bin/env bash
set -euo pipefail

rootdir="${ROOTDIR:-.tmp/generated/darkos-r43-rootfs}"
outdir="${OUTDIR:-.tmp/generated/images}"
image_name="${IMAGE_NAME:-dArkOS_R43_trixie_$(date +%Y%m%d).img}"
image_size="${IMAGE_SIZE:-8G}"
cross_compile="${CROSS_COMPILE:-aarch64-linux-gnu-}"
kernel_defconfig="${KERNEL_DEFCONFIG:-rk3566_r43_defconfig}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"

cd "$project_root"

mkdir -p "$outdir"

echo "Building R43 kernel Image, DTB and modules..."
make -C main ARCH=arm64 CROSS_COMPILE="$cross_compile" "$kernel_defconfig"
make -C main ARCH=arm64 CROSS_COMPILE="$cross_compile" -j"$(nproc)" Image modules rockchip/rk3566-r43m18.dtb

echo "Building base R43 rootfs..."
tools/r43/build-rootfs.sh "$rootdir"

echo "Building R43 EmulationStation layer..."
tools/r43/build-es-rootfs.sh "$rootdir" --enable-service

echo "Packaging R43 SD image..."
tools/r43/package-sd-image.sh "$rootdir" "$outdir/$image_name" "$image_size"

echo "Compressing image..."
7z a -v1950m "$outdir/$image_name.7z" "$outdir/$image_name"

echo "Done:"
ls -lh "$outdir"/"$image_name"*
