#!/usr/bin/env bash
# Copy the GameNight addon into a Godot project — and copy it *again* later,
# which is the point of this script existing.
#
# The addon is duplicated into each game rather than shared, because Godot
# projects have no notion of an external dependency. Duplication drifts: by the
# time this script was written, one game's copy was missing `declare_settings`
# and another was missing `notify_progress`, `request_overlay` and
# `request_start` — three protocol features, silently absent, in games that
# looked integrated.
#
#   sdk/godot/install.sh /path/to/project
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)/addons/gamenight"
dest="${1:?usage: install.sh /path/to/godot/project}"
[ -f "$dest/project.godot" ] || { echo "not a Godot project: $dest" >&2; exit 1; }

mkdir -p "$dest/addons/gamenight"
cp "$src"/gamenight.gd "$src"/screen.gd "$src"/plugin.gd "$src"/plugin.cfg "$dest/addons/gamenight/"
echo "copied the addon into $dest/addons/gamenight"

grep -q "GameNightScreen" "$dest/project.godot" || cat <<'MSG'

Add these to your project.godot [autoload] section (or enable the plugin in
the editor, which writes them for you):

    GameNight="*res://addons/gamenight/gamenight.gd"
    GameNightScreen="*res://addons/gamenight/screen.gd"
MSG
