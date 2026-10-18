# Working on Template Game

A GameNight couch game in Godot 4.5 (GL Compatibility). The GameNight game
playbook is the full guide: https://gamenight.ontola.io/docs/playbook

## Couch design rules

- Start playing at once; no setup screen before the first round.
- Every option is a GameNight setting (`SETTINGS` in main.gd) and also sits
  in the Start menu. Never bind Back: GameNight owns it.
- Use the players' colours, names and faces; keep text off the play field.
- Rounds keep going: results, `notify_finished`, next round.

## Check every change

    godot --headless --import                                   # parse errors show here
    godot --headless --fixed-fps 60 --path . -- --sim 4000 --seed 1
    python3 tests/lifecycle.py --godot godot                    # needs websockets

A script with a parse error makes headless runs hang instead of failing: run
the import first and look for `SCRIPT ERROR` or `Parse Error`.

## Keep it deterministic

All randomness goes through the global RNG, seeded once from `--seed`; the
simulation only moves in `_physics_process`. Never seed from the clock in
gameplay code, and never use a second unseeded RandomNumberGenerator. Then the
same seed replays the same run, and the sim hash, balance numbers and the
store clip stay reproducible.

## See it without a person

- `--shot out.png --frames 90`: bots play, frame 90 is saved and the game quits.
- `tools/capture_preview.sh` and `tools/encode_preview.py`: the five-second
  store clip, frame by frame. Add set-up flags (where to start, what to spawn)
  as the game grows, so a take can show the best moment.

## Ship it

Push to main. A manual run of the CI workflow with a `release` tag such as
`v0.1.0` publishes a GitHub release; with the `GAMENIGHT_API_TOKEN` secret
it also fills the store page from `gamenight.json` and `assets/gamenight`.
