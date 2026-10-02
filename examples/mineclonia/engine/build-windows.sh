#!/usr/bin/env bash
# Build in WSL/Linux; install the resulting ZIP using install.py on Windows.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
cache=${1:?Usage: build-windows.sh NEW_BUILD_DIRECTORY}
mkdir -p "$cache"
cache=$(cd "$cache" && pwd)
source="$cache/source"
# Refuse to overwrite an existing checkout or build.
if [[ -e "$source" || -e "$cache/build" ]]; then
  echo "Use a fresh directory. Existing source/build is preserved." >&2; exit 1
fi
git clone --branch 5.17.0 --depth 1 https://github.com/luanti-org/luanti.git "$source"
test "$(git -C "$source" rev-parse HEAD)" = c0e6812b1a4260bb25a1f606f70f55f4962bb97d
git -C "$source" apply --check "$here/controller.patch"
git -C "$source" apply "$here/controller.patch"
c++ -std=c++17 -I"$source/irr/include" "$here/test_binding.cpp" -o "$cache/test-binding"
"$cache/test-binding"
c++ -std=c++17 -I"$source/irr/include" "$here/test_host_frame.cpp" -o "$cache/test-host-frame"
"$cache/test-host-frame" "$cache/test.frame"
mkdir -p "$cache/toolchain"
cd "$cache"
bash "$source/util/buildbot/download_toolchain.sh" "$cache/toolchain"
export PATH="$cache/toolchain/bin:$PATH"
export EXISTING_MINETEST_DIR="$source"
bash "$source/util/buildbot/buildwin64.sh" "$cache/build" -DCMAKE_BUILD_TYPE=Release -DENABLE_GETTEXT=OFF
