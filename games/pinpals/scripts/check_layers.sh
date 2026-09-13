#!/bin/sh
# §11 "layer boundaries erode". Dependencies run app -> sim -> core, one way.
# core/ is pure Lua; sim/ may use love.physics and nothing else. Breaking this
# silently kills the headless test harness, so it is a hard gate.
#
# Comment lines are stripped first: the files document these rules in prose.
set -u
fail=0

code() { grep -rn "$1" $2 2>/dev/null | grep -v ':[0-9]*:[[:space:]]*--'; }

report() {
  out=$(code "$1" "$2")
  if [ -n "$out" ]; then printf 'FAIL: %s\n%s\n' "$3" "$out"; fail=1; fi
}

report 'love\.'                     'core/'      'core/ must be pure Lua (no love.* at all)'
report 'love\.\(graphics\|window\|keyboard\|joystick\|audio\|mouse\|timer\|event\)' \
                                    'sim/'       'sim/ may only use love.physics'
report 'require *( *["'"'"']app\.'  'core/ sim/' 'dependencies must point app -> sim -> core, never back'
report 'require *( *["'"'"']sim\.'  'core/'      'core/ must not depend on sim/'

[ $fail -eq 0 ] && echo "layers: core pure, sim physics-only, deps one-way"
exit $fail
