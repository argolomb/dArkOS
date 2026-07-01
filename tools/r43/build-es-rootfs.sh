#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/r43/build-es-rootfs.sh [ROOTDIR] [--enable-service]

Builds and installs the R43 EmulationStation layer into an existing
tools/r43/build-rootfs.sh rootfs. This does not import files from a
downloaded handheld image.

Default ROOTDIR:
  .tmp/generated/darkos-r43-rootfs
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"
rootdir="${1:-.tmp/generated/darkos-r43-rootfs}"
enable_service=0

shift $(( $# >= 1 ? 1 : 0 ))
for arg in "$@"; do
  case "$arg" in
    --enable-service) enable_service=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

rootdir="$(realpath -m "$rootdir")"

cd "$project_root"

if [[ ! -e "$rootdir/sbin/init" ]]; then
  echo "Missing rootfs init: $rootdir/sbin/init" >&2
  exit 1
fi

if [[ ! -f "$rootdir/usr/bin/qemu-aarch64-static" ]]; then
  sudo cp /usr/bin/qemu-aarch64-static "$rootdir/usr/bin/"
fi

cleanup_mounts() {
  for mountpoint in "$rootdir/dev/pts" "$rootdir/dev" "$rootdir/sys" "$rootdir/proc"; do
    if mountpoint -q "$mountpoint"; then
      sudo umount -l "$mountpoint"
    fi
  done
}
trap cleanup_mounts EXIT

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

echo "Installing R43 EmulationStation build/runtime dependencies..."
sudo chroot "$rootdir" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  build-essential git cmake pkg-config ca-certificates wget curl dialog evtest \
  iproute2 iw rfkill console-setup fonts-droid-fallback \
  libfreeimage-dev libsdl2-dev libsdl2-mixer-dev libfreetype-dev \
  libcurl4-openssl-dev libvlc-dev libasound2-dev libdrm-dev libgbm-dev \
  libxkbcommon-dev libudev-dev libpng-dev
'

echo "Installing Mali G52 userspace..."
arch_dir="$rootdir/usr/lib/aarch64-linux-gnu"
mali_so="libmali-bifrost-g52-g13p0-gbm.so"
sudo mkdir -p "$arch_dir"
if [[ ! -f "$arch_dir/$mali_so" ]]; then
  sudo wget -t 3 -T 60 --no-check-certificate \
    "https://github.com/christianhaitian/rk3566_core_builds/raw/refs/heads/master/mali/aarch64/$mali_so" \
    -O "$arch_dir/$mali_so"
fi
(
  cd "$arch_dir"
  sudo ln -sf "$mali_so" libMali.so
  for lib in \
    libEGL.so libEGL.so.1 libEGL.so.1.1.0 \
    libGLES_CM.so libGLES_CM.so.1 \
    libGLESv1_CM.so libGLESv1_CM.so.1 libGLESv1_CM.so.1.1.0 \
    libGLESv2.so libGLESv2.so.2 libGLESv2.so.2.0.0 libGLESv2.so.2.1.0 \
    libGLESv3.so libGLESv3.so.3 \
    libgbm.so libgbm.so.1 libgbm.so.1.0.0 \
    libmali.so libmali.so.1 libMaliOpenCL.so libOpenCL.so \
    libwayland-egl.so libwayland-egl.so.1 libwayland-egl.so.1.0.0; do
    sudo ln -sf libMali.so "$lib"
  done
)

if [[ -f "$project_root/misc/rk3566/vulkan/libmali-hook.so.1.9.0" ]]; then
  sudo cp "$project_root/misc/rk3566/vulkan/libmali-hook.so.1.9.0" "$arch_dir/"
  sudo ln -sf /usr/lib/aarch64-linux-gnu/libmali-hook.so.1.9.0 "$arch_dir/libmali-hook.so.1"
  sudo ln -sf /usr/lib/aarch64-linux-gnu/libmali-hook.so.1 "$arch_dir/libmali-hook.so"
fi
if [[ -f "$project_root/misc/rk3566/vulkan/libvulkan.so.1.3.274" ]]; then
  sudo cp "$project_root/misc/rk3566/vulkan/libvulkan.so.1.3.274" "$arch_dir/"
  sudo ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1.3.274 "$arch_dir/libvulkan.so.1"
  sudo ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$arch_dir/libvulkan.so"
fi
if [[ -f "$project_root/misc/rk3566/vulkan/rk_vk.json" ]]; then
  sudo mkdir -p "$rootdir/usr/share/vulkan/icd.d"
  sudo cp "$project_root/misc/rk3566/vulkan/rk_vk.json" "$rootdir/usr/share/vulkan/icd.d/rk_vk.json"
fi

sudo chroot "$rootdir" ldconfig

echo "Building EmulationStation-fcamod inside rootfs..."
sudo chroot "$rootdir" bash -c '
set -e
cd /home/ark
rm -rf EmulationStation-fcamod
git clone --recursive --depth=1 https://github.com/christianhaitian/EmulationStation-fcamod -b 503noTTS
cd EmulationStation-fcamod
git submodule update --init
cmake \
  -DSCREENSCRAPER_DEV_LOGIN="" \
  -DGAMESDB_APIKEY="" \
  -DSCREENSCRAPER_SOFTNAME="dArkOS-R43" \
  .
make -j"$(nproc)"
mkdir -p /usr/bin/emulationstation
cp -a emulationstation /usr/bin/emulationstation/
cp -a resources /usr/bin/emulationstation/
chmod 755 /usr/bin/emulationstation/emulationstation
cd /home/ark
rm -rf EmulationStation-fcamod
'

echo "Installing R43 EmulationStation configs and wrappers..."
es_input_cfg="$project_root/Emulationstation/es_input.cfg.r43"
es_settings_cfg="$project_root/Emulationstation/es_settings.cfg.r43"
if [[ ! -f "$es_input_cfg" ]]; then
  es_input_cfg="$project_root/Emulationstation/es_input.cfg.rk2023"
fi
if [[ ! -f "$es_settings_cfg" ]]; then
  es_settings_cfg="$project_root/Emulationstation/es_settings.cfg.rk2023"
fi

sudo mkdir -p \
  "$rootdir/etc/emulationstation" \
  "$rootdir/home/ark/.emulationstation" \
  "$rootdir/home/ark/.config/retroarch" \
  "$rootdir/usr/local/bin" \
  "$rootdir/etc/systemd/system"

sudo cp "$project_root/Emulationstation/es_systems.cfg.rk3566-64bit_Only" "$rootdir/etc/emulationstation/es_systems.cfg"
sudo cp "$es_input_cfg" "$rootdir/etc/emulationstation/es_input.cfg"
sudo cp "$es_settings_cfg" "$rootdir/home/ark/.emulationstation/es_settings.cfg"
sudo cp -R "$project_root/Emulationstation/scripts" "$rootdir/home/ark/.emulationstation/"
if [[ -d "$project_root/Emulationstation/fonts" ]]; then
  sudo cp "$project_root"/Emulationstation/fonts/* "$rootdir/usr/bin/emulationstation/resources/" 2>/dev/null || true
fi

cat <<'EOF' | sudo tee "$rootdir/usr/bin/emulationstation/emulationstation-r43.sh" >/dev/null
#!/bin/bash
set -e

export SDL_ASSERT="${SDL_ASSERT:-always_ignore}"
export SDL_VIDEO_EGL_DRIVER="${SDL_VIDEO_EGL_DRIVER:-libEGL.so}"
export TERM="${TERM:-linux}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

sudo chmod 666 /dev/tty1 2>/dev/null || true
exec /usr/bin/emulationstation/emulationstation "$@"
EOF
sudo chmod 755 "$rootdir/usr/bin/emulationstation/emulationstation-r43.sh"

cat <<'EOF' | sudo tee "$rootdir/usr/local/bin/ip" >/dev/null
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = "wlan0" ]; then
    exit 0
  fi
done
exec /usr/sbin/ip "$@"
EOF
sudo chmod 755 "$rootdir/usr/local/bin/ip"

cat <<'EOF' | sudo tee "$rootdir/usr/local/bin/iw" >/dev/null
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = "wlan0" ]; then
    exit 0
  fi
done
exec /usr/sbin/iw "$@"
EOF
sudo chmod 755 "$rootdir/usr/local/bin/iw"

printf 'R43\n' | sudo tee "$rootdir/home/ark/.config/.DEVICE" >/dev/null
printf 'github-action-stage1\n' | sudo tee "$rootdir/home/ark/.config/.VERSION" >/dev/null
printf 'menu_driver = "rgui"\n' | sudo tee "$rootdir/home/ark/.config/retroarch/retroarch.cfg" >/dev/null

cat <<'EOF' | sudo tee "$rootdir/etc/systemd/system/emulationstation.service" >/dev/null
[Unit]
Description=R43 EmulationStation
After=systemd-user-sessions.service

[Service]
Type=simple
User=ark
WorkingDirectory=/home/ark
ExecStart=/usr/bin/emulationstation/emulationstation-r43.sh
RuntimeDirectory=r43-es
RuntimeDirectoryMode=0700
Environment="XDG_RUNTIME_DIR=/run/r43-es"
Environment="SDL_VIDEO_EGL_DRIVER=libEGL.so"
Environment="PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo chroot "$rootdir" chown -R ark:ark /home/ark /etc/emulationstation
sudo chroot "$rootdir" usermod -aG video,render,input,audio ark
if [[ "$enable_service" == 1 ]]; then
  sudo chroot "$rootdir" systemctl disable getty@tty1.service >/dev/null 2>&1 || true
  sudo chroot "$rootdir" systemctl enable emulationstation
else
  sudo chroot "$rootdir" systemctl disable emulationstation >/dev/null 2>&1 || true
fi

sudo chroot "$rootdir" apt-get clean
sudo rm -rf "$rootdir/var/lib/apt/lists/"*

cat <<EOF
Installed R43 EmulationStation layer into:
  $rootdir

Service enabled: $enable_service
EOF
