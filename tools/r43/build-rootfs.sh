#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/r43/build-rootfs.sh [ROOTDIR]

Builds a bootable dArkOS-style Debian arm64 rootfs for the R43 SD boot path.
This is a practical bring-up rootfs, not the full emulator image.

Default ROOTDIR:
  .tmp/generated/darkos-r43-rootfs

After this succeeds, write it to the SD rootfs partition with:
  tools/write-rootfs-btrfs-adb.sh .tmp/generated/darkos-r43-rootfs 4G --yes-i-know-this-erases
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"
rootdir="${1:-.tmp/generated/darkos-r43-rootfs}"
mkdir -p "$(dirname "$rootdir")"
rootdir="$(realpath -m "$rootdir")"
suite="${DEBIAN_CODE_NAME:-trixie}"
mirror="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"
kernel_src="$project_root/main"
cross_compile="${CROSS_COMPILE:-aarch64-linux-gnu-}"
kernel_defconfig="${KERNEL_DEFCONFIG:-rk3566_r43_defconfig}"

cd "$project_root"

for tool in debootstrap qemu-aarch64-static sudo rsync chroot "${cross_compile}gcc"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if ! sudo -n true >/dev/null 2>&1; then
  echo "This build requires passwordless sudo, as expected by dArkOS." >&2
  echo "Run it from a host terminal with sudo configured, or run FreeSudo.sh first." >&2
  exit 1
fi

if [[ ! -d "$kernel_src" ]]; then
  echo "Missing kernel tree: $kernel_src" >&2
  exit 1
fi

if [[ ! -f "$kernel_src/arch/arm64/boot/Image" ]]; then
  echo "Missing compiled kernel Image in $kernel_src" >&2
  exit 1
fi

cleanup_mounts() {
  for mountpoint in "$rootdir/dev/pts" "$rootdir/dev" "$rootdir/proc" "$rootdir/sys"; do
    if mountpoint -q "$mountpoint"; then
      sudo umount -l "$mountpoint"
    fi
  done
}
trap cleanup_mounts EXIT

if [[ ! -e "$rootdir/debootstrap/debootstrap" ]]; then
  echo "Bootstrapping Debian $suite arm64 into $rootdir..."
  sudo rm -rf "$rootdir"
  sudo debootstrap --no-check-gpg --include=eatmydata --resolve-deps --arch=arm64 --foreign "$suite" "$rootdir" "$mirror"
fi

sudo cp /usr/bin/qemu-aarch64-static "$rootdir/usr/bin/"

sudo mkdir -p "$rootdir/dev" "$rootdir/dev/pts" "$rootdir/proc" "$rootdir/sys"
if ! mountpoint -q "$rootdir/proc"; then
  sudo mount -t proc proc "$rootdir/proc"
fi
if ! mountpoint -q "$rootdir/sys"; then
  sudo mount --rbind /sys "$rootdir/sys"
  sudo mount --make-rslave "$rootdir/sys"
fi
if ! mountpoint -q "$rootdir/dev"; then
  sudo mount --rbind /dev "$rootdir/dev"
  sudo mount --make-rslave "$rootdir/dev"
fi
if ! mountpoint -q "$rootdir/dev/pts"; then
  sudo mount -t devpts devpts "$rootdir/dev/pts" -o newinstance,ptmxmode=0666,mode=0620
fi
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' | sudo tee "$rootdir/etc/resolv.conf" >/dev/null

if ! sudo chroot "$rootdir" sh -c 'test -d /proc/self && test -r /proc/mounts'; then
  echo "Failed to make /proc visible inside $rootdir" >&2
  exit 1
fi

if [[ ! -f "$rootdir/.darkos-r43-second-stage" ]]; then
  echo "Running debootstrap second stage..."
  sudo chroot "$rootdir" /debootstrap/debootstrap --second-stage
  sudo touch "$rootdir/.darkos-r43-second-stage"
fi

echo "Installing base runtime packages..."
sudo chroot "$rootdir" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
eatmydata apt-get install -y \
  btrfs-progs initramfs-tools sudo evtest network-manager systemd-sysv \
  locales locales-all openssh-server dosfstools alsa-utils kmod udev \
  ca-certificates bash-completion less nano
'

echo "Configuring locale, user, fstab and services..."
sudo sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$rootdir/etc/locale.gen"
printf 'LANG="en_US.UTF-8"\n' | sudo tee "$rootdir/etc/default/locale" >/dev/null
sudo chroot "$rootdir" locale-gen

if ! sudo chroot "$rootdir" id ark >/dev/null 2>&1; then
  sudo chroot "$rootdir" useradd ark -k /etc/skel -d /home/ark -m -s /bin/bash
  echo 'ark:ark' | sudo chroot "$rootdir" chpasswd
fi
sudo chroot "$rootdir" chage -I -1 -m 0 -M 99999 -E -1 ark
sudo mkdir -p "$rootdir/etc/sudoers.d"
printf 'ark     ALL= NOPASSWD: ALL\n' | sudo tee "$rootdir/etc/sudoers.d/ark-no-sudo-password" >/dev/null
printf 'Defaults        !secure_path\n' | sudo tee "$rootdir/etc/sudoers.d/ark-no-secure-path" >/dev/null
sudo chmod 0440 "$rootdir/etc/sudoers.d/ark-no-sudo-password" "$rootdir/etc/sudoers.d/ark-no-secure-path"
sudo chroot "$rootdir" usermod -aG video,sudo,render,netdev,input,audio,adm ark

printf 'r43\n' | sudo tee "$rootdir/etc/hostname" >/dev/null
cat <<'EOF' | sudo tee "$rootdir/etc/hosts" >/dev/null
127.0.0.1	localhost
127.0.1.1	r43
EOF

cat <<'EOF' | sudo tee "$rootdir/etc/fstab" >/dev/null
/dev/mmcblk1p4 / btrfs defaults,noatime,compress=zstd:1,ssd_spread 0 0
/dev/mmcblk1p3 /boot vfat defaults,noatime 0 0
/dev/mmcblk1p5 /roms exfat defaults,auto,umask=000,uid=1000,gid=1000,noatime 0 0
EOF

sudo mkdir -p "$rootdir/boot" "$rootdir/roms" "$rootdir/home/ark/.config" "$rootdir/usr/local/bin"
sudo chroot "$rootdir" systemctl enable NetworkManager
sudo chroot "$rootdir" systemctl disable ssh || true

echo "Installing kernel modules and firmware from $kernel_src..."
make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$cross_compile" "$kernel_defconfig"
make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$cross_compile" modules
sudo make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$cross_compile" INSTALL_MOD_PATH="$rootdir" modules_install
sudo rsync -aL --ignore-errors "$kernel_src/lib/firmware/" "$rootdir/lib/firmware/" 2>/dev/null || true
if [[ -d "$project_root/firmware" ]]; then
  sudo rsync -a "$project_root/firmware/" "$rootdir/lib/firmware/" 2>/dev/null || true
fi

kernel_release="$(make -s -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$cross_compile" kernelrelease)"
sudo chroot "$rootdir" depmod "$kernel_release"
sudo cp "$kernel_src/.config" "$rootdir/boot/config-$kernel_release"

echo "Adding R43 marker files..."
cat <<EOF | sudo tee "$rootdir/etc/darkos-r43-build" >/dev/null
rootfs=darkos-r43-base
kernel=$kernel_release
source=$kernel_src
EOF

sudo chroot "$rootdir" chown -R ark:ark /home/ark
sudo sync

cleanup_mounts
echo "Built dArkOS R43 base rootfs at $rootdir"
