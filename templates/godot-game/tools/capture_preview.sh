#!/usr/bin/env bash
# Record the takes for the five-second GameNight store clip: the real game with
# bots playing, rendered frame by frame (--fixed-fps 30 --write-movie), so the
# same seed gives the same frames. Writes PNG frames per take to OUT/<take>/;
# tools/encode_preview.py cuts them into one clip.
#   GODOT=... tools/capture_preview.sh OUT
# Add a take per moment worth showing: a different seed, level or set-up flag.
set -euo pipefail
out=$(realpath -m "$1")
cd "$(dirname "$0")/.."
take() {
	local name=$1; shift
	mkdir -p "$out/$name"
	xvfb-run -a -s "-screen 0 960x540x24" timeout 600 "${GODOT:-godot}" --resolution 960x540 \
		--audio-driver Dummy --fixed-fps 30 --write-movie "$out/$name/f.png" --quit-after 160 \
		--path . -- --shot "$out/$name/end.png" --frames 100000 "$@" > "$out/$name/log.txt" 2>&1
}
take open --seed 11
take crowd --seed 12
take late --seed 13
