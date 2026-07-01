#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/r43/package-sd-image.sh ROOTDIR OUT_IMG [SIZE]

Packages an R43 SD image using the already-built kernel/DTB and ROOTDIR.

Default SIZE:
  8G
USAGE
}

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 2
fi

rootdir="$(realpath -m "$1")"
out_img="$(realpath -m "$2")"
image_size="${3:-8G}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"

kernel="$project_root/main/arch/arm64/boot/Image"
dtb="$project_root/main/arch/arm64/boot/dts/rockchip/rk3566-r43m18.dtb"
fit_dir="$project_root/.tmp/generated/r43-boot"
fit_kernel="$fit_dir/Image"
fit_dtb="$fit_dir/rk3566-r43m18.dtb"
fit_resource="$fit_dir/resource.img"
fit_its="$fit_dir/boot-r43.its"
boot_itb="$fit_dir/boot.itb"
bootargs='earlycon=uart8250,mmio32,0xfe660000 console=ttyS2,1500000n8 root=/dev/mmcblk1p4 rootwait rw rootfstype=btrfs loglevel=7 consoleblank=0'
btrfs_features="${BTRFS_FEATURES:-^no-holes}"

for tool in fdtput mkimage sgdisk mkfs.vfat mkfs.btrfs losetup partprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ ! -e "$rootdir/sbin/init" ]]; then
  echo "Missing rootfs init: $rootdir/sbin/init" >&2
  exit 1
fi
if [[ ! -f "$kernel" || ! -f "$dtb" ]]; then
  echo "Missing built kernel or DTB. Build main/ first." >&2
  exit 1
fi

mkdir -p "$(dirname "$out_img")"
rm -f "$out_img"

echo "Refreshing FIT boot artifacts..."
mkdir -p "$fit_dir"
cp "$kernel" "$fit_kernel"
cp "$dtb" "$fit_dtb"
fdtput -t s "$fit_dtb" /chosen bootargs "$bootargs"
resource_tmp="$(mktemp -d)"
trap 'rm -rf "$resource_tmp"; if [[ -n "${loopdev:-}" ]]; then sudo losetup -d "$loopdev" 2>/dev/null || true; fi' EXIT
cp "$fit_dtb" "$resource_tmp/rk-kernel.dtb"
cp "$project_root/main/logo.bmp" "$resource_tmp/logo.bmp"
cp "$project_root/main/logo_kernel.bmp" "$resource_tmp/logo_kernel.bmp"
(
  cd "$resource_tmp"
  "$project_root/main/scripts/resource_tool" --pack logo.bmp logo_kernel.bmp rk-kernel.dtb >/dev/null
)
cp "$resource_tmp/resource.img" "$fit_resource"
cp "$script_dir/sdboot/boot-r43.its" "$fit_its"
(cd "$fit_dir" && mkimage -E -p 0x1200 -f "$(basename "$fit_its")" "$(basename "$boot_itb")")

echo "Creating image: $out_img ($image_size)"
truncate -s "$image_size" "$out_img"
loopdev="$(sudo losetup --show --partscan --find "$out_img")"

sudo sgdisk --zap-all "$loopdev"
sudo sgdisk \
  --new=1:32768:294911 --change-name=1:nand_boot --typecode=1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --new=2:24576:32767 --change-name=2:resource --typecode=2:D46E0000-0000-457F-8000-220D000030DB \
  --new=3:294912:557055 --change-name=3:dArkOS_Fat --typecode=3:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --new=4:557056:15445614 --change-name=4:rootfs --typecode=4:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --new=5:15446016:0 --change-name=5:ROMS --typecode=5:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  "$loopdev"
sudo partprobe "$loopdev"
sleep 2

part() {
  local n="$1"
  if [[ -e "${loopdev}p${n}" ]]; then
    printf '%s\n' "${loopdev}p${n}"
  else
    printf '%s\n' "${loopdev}${n}"
  fi
}

p1="$(part 1)"
p2="$(part 2)"
p3="$(part 3)"
p4="$(part 4)"
p5="$(part 5)"

sudo mkfs.vfat -F 32 -n NAND_BOOT "$p1"
sudo mkfs.vfat -F 32 -n dArkOS_Fat "$p3"
if command -v mkfs.exfat >/dev/null 2>&1; then
  sudo mkfs.exfat -n ROMS "$p5"
else
  sudo mkfs.vfat -F 32 -n ROMS "$p5"
fi
sudo dd if="$fit_resource" of="$p2" bs=512 conv=fsync,notrunc status=none
mkfs_btrfs_args=(-q -f -L ROOTFS)
if [[ -n "$btrfs_features" ]]; then
  mkfs_btrfs_args+=(-O "$btrfs_features")
fi
sudo mkfs.btrfs "${mkfs_btrfs_args[@]}" -r "$rootdir" "$p4"

boot_mount="$(mktemp -d)"
sudo mount "$p3" "$boot_mount"
sudo cp "$kernel" "$boot_mount/Image"
sudo cp "$fit_dtb" "$boot_mount/rk3566-r43m18.dtb"
sudo cp "$boot_itb" "$boot_mount/boot.itb"
sudo mkdir -p "$boot_mount/extlinux"
cat <<EOF | sudo tee "$boot_mount/extlinux/extlinux.conf" >/dev/null
LABEL dArkOS
  LINUX /Image
  FDT /rk3566-r43m18.dtb
  APPEND $bootargs
EOF
sync
sudo umount "$boot_mount"

sudo mount "$p1" "$boot_mount"
sudo cp "$kernel" "$boot_mount/Image"
sudo cp "$fit_dtb" "$boot_mount/rk3566-r43m18.dtb"
sudo cp "$boot_itb" "$boot_mount/boot.itb"
sudo mkdir -p "$boot_mount/extlinux"
cat <<EOF | sudo tee "$boot_mount/extlinux/extlinux.conf" >/dev/null
LABEL dArkOS
  LINUX /Image
  FDT /rk3566-r43m18.dtb
  APPEND $bootargs
EOF
sync
sudo umount "$boot_mount"
rm -rf "$boot_mount"

sudo losetup -d "$loopdev"
loopdev=""

echo "Packaged R43 SD image: $out_img"
