#!/bin/bash
# GameNight cloud setup: Godot, Flutter, Rust/Bevy deps, headless GPU for screenshots.
# Source for the setup script of the "Default - Full" Claude Code cloud environment.
# Edit here, then paste it into the environment settings (it runs as root on fresh containers).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# love's postinst needs its man page, which the image's dpkg excludes.
mkdir -p /usr/share/man/man6
echo 'path-include=/usr/share/man/man6/love*' > /etc/dpkg/dpkg.cfg.d/zz-love-man
apt-get update -qq
apt-get install -y -qq --no-install-recommends unzip xz-utils xvfb mesa-vulkan-drivers \
  libgl1-mesa-dri libvulkan1 vulkan-tools pkg-config libudev-dev libasound2-dev \
  libx11-dev libxkbcommon-dev libwayland-dev libxcursor-dev libxi-dev libxrandr-dev \
  love ffmpeg imagemagick >/dev/null

# Godot: `godot` = 4.5.2 (most games), plus godot-4.6 and godot-4.7.
get_godot() {
  local v=$1 name=$2 bin=/opt/godot/Godot_v$1-stable_linux.x86_64
  if [ ! -x "$bin" ]; then
    mkdir -p /opt/godot
    curl -fsSL --retry 3 -o /tmp/godot.zip \
      "https://github.com/godotengine/godot-builds/releases/download/$v-stable/Godot_v$v-stable_linux.x86_64.zip"
    unzip -oq /tmp/godot.zip -d /opt/godot && rm /tmp/godot.zip
  fi
  ln -sf "$bin" "/usr/local/bin/$name"
}
get_godot 4.5.2 godot
get_godot 4.6.2 godot-4.6
get_godot 4.7.1 godot-4.7

# Flutter 3.47.6 (same as mobile.yml).
if [ ! -x /opt/flutter/bin/flutter ]; then
  curl -fsSL --retry 3 \
    https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.6-stable.tar.xz \
    | tar -xJ -C /opt
fi
git config --global --add safe.directory /opt/flutter
ln -sf /opt/flutter/bin/flutter /usr/local/bin/flutter
ln -sf /opt/flutter/bin/dart /usr/local/bin/dart
flutter config --no-analytics >/dev/null 2>&1 || true

# Warm dependency caches when the repos are present.
R=/home/user
[ -d $R/gamenight ] && (cd $R/gamenight && cargo fetch -q) || true
[ -d $R/gamenight/mobile ] && (cd $R/gamenight/mobile && flutter pub get >/dev/null) || true
echo "GameNight setup done"
