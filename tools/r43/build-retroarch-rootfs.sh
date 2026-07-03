#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/r43/build-retroarch-rootfs.sh [ROOTDIR]

Builds and installs the R43 RetroArch layer into an existing R43 rootfs.
RetroArch itself is compiled through christianhaitian/rk3566_core_builds,
matching the normal dArkOS RK3566 path. Libretro cores are pulled from the
same christianhaitian/retroarch-cores repo used by dArkOS.

Environment:
  R43_RETROARCH_CORES_FILE  Core list file. Default: retroarch_cores.txt
  R43_RETROARCH_CORE_REPO   Core branch/repo path. Default: rg503
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"
rootdir="${1:-.tmp/generated/darkos-r43-rootfs}"
rootdir="$(realpath -m "$rootdir")"
cores_file="${R43_RETROARCH_CORES_FILE:-$project_root/retroarch_cores.txt}"
core_repo="${R43_RETROARCH_CORE_REPO:-rg503}"

cd "$project_root"

if [[ ! -e "$rootdir/sbin/init" ]]; then
  echo "Missing rootfs init: $rootdir/sbin/init" >&2
  exit 1
fi
if [[ ! -f "$cores_file" ]]; then
  echo "Missing RetroArch core list: $cores_file" >&2
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

echo "Installing RetroArch build/runtime dependencies..."
sudo chroot "$rootdir" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
eatmydata apt-get install -y \
  build-essential git cmake pkg-config premake4 ca-certificates wget curl unzip jq \
  autoconf automake libtool gettext nasm yasm python3 python3-dev \
  zlib1g-dev libssl-dev libxml2-dev libdrm-dev libgbm-dev libegl-dev libgles-dev \
  libsdl2-dev libasound2-dev libudev-dev libxkbcommon-dev libfreetype-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libv4l-dev \
  libusb-1.0-0-dev libpulse-dev libopenal-dev
'

echo "Building RetroArch for RK3566 inside rootfs..."
sudo chroot "$rootdir" bash -c '
set -e
cd /home/ark
rm -rf rk3566_core_builds
git clone --depth=1 https://github.com/christianhaitian/rk3566_core_builds.git
cd rk3566_core_builds
chmod 755 builds-alt.sh
eatmydata ./builds-alt.sh retroarch
test -x retroarch64/retroarch
'

echo "Installing RetroArch binary, filters and configs..."
sudo mkdir -p \
  "$rootdir/opt/retroarch/bin" \
  "$rootdir/home/ark/.config/retroarch/cores" \
  "$rootdir/home/ark/.config/retroarch/filters/audio" \
  "$rootdir/home/ark/.config/retroarch/filters/video" \
  "$rootdir/home/ark/.config/retroarch/autoconfig/udev" \
  "$rootdir/usr/local/bin"

sudo cp -a "$rootdir/home/ark/rk3566_core_builds/retroarch64/retroarch" "$rootdir/opt/retroarch/bin/retroarch"
sudo cp -a "$rootdir/home/ark/rk3566_core_builds/retroarch/gfx/video_filters/"*.so "$rootdir/home/ark/.config/retroarch/filters/video/" 2>/dev/null || true
sudo cp -a "$rootdir/home/ark/rk3566_core_builds/retroarch/gfx/video_filters/"*.filt "$rootdir/home/ark/.config/retroarch/filters/video/" 2>/dev/null || true
sudo cp -a "$rootdir/home/ark/rk3566_core_builds/retroarch/libretro-common/audio/dsp_filters/"*.so "$rootdir/home/ark/.config/retroarch/filters/audio/" 2>/dev/null || true
sudo cp -a "$rootdir/home/ark/rk3566_core_builds/retroarch/libretro-common/audio/dsp_filters/"*.dsp "$rootdir/home/ark/.config/retroarch/filters/audio/" 2>/dev/null || true

sudo cp "$project_root/retroarch/configs/retroarch.cfg.rk2023" "$rootdir/home/ark/.config/retroarch/retroarch.cfg"
sudo cp "$project_root/retroarch/configs/retroarch.cfg.spectate" "$rootdir/home/ark/.config/retroarch/retroarch.cfg.spectate"
sudo cp "$project_root/retroarch/configs/retroarch.cfg.vert" "$rootdir/home/ark/.config/retroarch/retroarch.cfg.vert"
sudo cp "$project_root/retroarch/configs/retroarch-core-options.cfg.rk2023" "$rootdir/home/ark/.config/retroarch/retroarch-core-options.cfg"
sudo cp "$project_root"/retroarch/configs/controller/*.cfg "$rootdir/home/ark/.config/retroarch/autoconfig/udev/" 2>/dev/null || true

cat <<'EOF' | sudo tee "$rootdir/home/ark/.config/retroarch/retroarch-r43.cfg" >/dev/null
video_driver = "gl"
video_fullscreen = "true"
video_fullscreen_x = "480"
video_fullscreen_y = "272"
custom_viewport_width = "480"
custom_viewport_height = "272"
custom_viewport_x = "0"
custom_viewport_y = "0"
aspect_ratio_index = "22"
audio_driver = "alsathread"
input_driver = "udev"
input_joypad_driver = "udev"
menu_driver = "rgui"
core_updater_buildbot_cores_url = "https://raw.githubusercontent.com/christianhaitian/retroarch-cores/rg503/aarch64/"
EOF

cat <<'EOF' | sudo tee "$rootdir/usr/local/bin/retroarch" >/dev/null
#!/bin/bash
set -e
export SDL_ASSERT="${SDL_ASSERT:-always_ignore}"
export SDL_VIDEO_EGL_DRIVER="${SDL_VIDEO_EGL_DRIVER:-libEGL.so}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
exec /opt/retroarch/bin/retroarch \
  -c /home/ark/.config/retroarch/retroarch.cfg \
  --appendconfig=/home/ark/.config/retroarch/retroarch-r43.cfg \
  "$@"
EOF
sudo chmod 755 "$rootdir/usr/local/bin/retroarch"

cat <<'EOF' | sudo tee "$rootdir/usr/local/bin/r43-retroarch-dispatch" >/dev/null
#!/bin/bash
set -e
emulator="${1:-retroarch}"
core="${2:-}"
shift 2 || true

case "$emulator" in
  retroarch|"")
    if [ -n "$core" ] && [ -f "/home/ark/.config/retroarch/cores/${core}_libretro.so" ]; then
      exec /usr/local/bin/retroarch -L "/home/ark/.config/retroarch/cores/${core}_libretro.so" "$@"
    fi
    ;;
esac

echo "Unsupported or missing R43 emulator/core: ${emulator}/${core}" >&2
exit 127
EOF
sudo chmod 755 "$rootdir/usr/local/bin/r43-retroarch-dispatch"

cat <<'EOF' | sudo tee "$rootdir/usr/local/bin/perfmax" >/dev/null
#!/bin/sh
exit 0
EOF
cat <<'EOF' | sudo tee "$rootdir/usr/local/bin/perfnorm" >/dev/null
#!/bin/sh
exit 0
EOF
sudo chmod 755 "$rootdir/usr/local/bin/perfmax" "$rootdir/usr/local/bin/perfnorm"

for helper in \
  amiga apple2 atomiswave b2 coco doom dragon dreamcast easyrpg ecwolf freej2me \
  gametank gx4000 n64 naomi neogeocd ppsspp saturn scummvm ti99; do
  sudo ln -sf r43-retroarch-dispatch "$rootdir/usr/local/bin/${helper}.sh"
done

echo "Downloading libretro cores from christianhaitian/retroarch-cores ($core_repo/aarch64)..."
while read -r core; do
  [[ -z "$core" || "$core" =~ ^# ]] && continue
  echo "  core: $core"
  sudo chroot "$rootdir" bash -c "
set -e
tmp=\"/tmp/${core}_libretro.so.zip\"
if wget -t 5 -T 30 --no-check-certificate \
  \"https://github.com/christianhaitian/retroarch-cores/raw/${core_repo}/aarch64/${core}_libretro.so.zip\" \
  -O \"\$tmp\"; then
  unzip -o \"\$tmp\" -d /home/ark/.config/retroarch/cores/
  rm -f \"\$tmp\"
else
  echo \"Warning: ${core}_libretro.so was not downloaded\" >&2
fi
if ! wget -t 3 -T 30 --no-check-certificate \
  \"https://github.com/libretro/libretro-core-info/raw/refs/heads/master/${core}_libretro.info\" \
  -O \"/home/ark/.config/retroarch/cores/${core}_libretro.info\"; then
  rm -f \"/home/ark/.config/retroarch/cores/${core}_libretro.info\"
fi
"
done <"$cores_file"

echo "Installing RetroArch assets and GLSL shaders..."
sudo chroot "$rootdir" bash -c '
set -e
cd /home/ark/.config/retroarch
rm -rf assets shaders/shaders_glsl
git clone --depth=1 https://github.com/libretro/retroarch-assets.git assets
mkdir -p shaders
git clone --depth=1 https://github.com/libretro/glsl-shaders.git shaders/shaders_glsl
'

sudo rm -rf "$rootdir/home/ark/rk3566_core_builds"
sudo chroot "$rootdir" chown -R ark:ark /home/ark/.config/retroarch
sudo chroot "$rootdir" chmod 755 /opt/retroarch/bin/retroarch
sudo chroot "$rootdir" apt-get clean
sudo rm -rf "$rootdir/var/lib/apt/lists/"*

cat <<EOF
Installed R43 RetroArch layer into:
  $rootdir
EOF
