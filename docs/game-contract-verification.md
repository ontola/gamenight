# Game contract verification

The wire contract is `docs/protocol.md`. Executable release requirements live in
`contract/requirements.json`. Neither a catalog integration label nor a protocol
handshake is proof of the complete implementation.

## One matrix, including missing integrations

`scripts/game-contract.py` discovers **every** `catalog/games/*.json` entry. Each
feature gets `passed`, `failed`, `untested`, or (only for optional requirements)
`not_applicable`. Missing runners stay visible as `untested`; they are never omitted.
Packaged `.love` games are discovered from the package directory, not a second
hardcoded certification list. A package with no catalog entry or an empty pack fails.

Each run emits `matrix.json`, `matrix.md`, raw certifier JSON, and command logs.
Evidence is tied to the source commit, operating system and SHA-256 of the tested
package. Logs have their own hashes. Dirty worktrees are marked and cannot provide
release evidence. Never reuse an output directory from an earlier run.

The current automatic runners verify, per packaged LÖVE game:

- protocol lifecycle against a real embedded daemon;
- rendering a real frame from the package;
- authenticated prepare with sparse seats, followed by process exit on host disconnect.

Protocol subchecks are included individually. Skipped subchecks remain untested.
The protocol pause check only observes host state. It does **not** prove simulation
or audio paused. First-frame rendering does **not** prove prewarming or correct
player artwork. The instrumented `scripts/test-love-integration.py` runner also observes live
names, colours and avatar draw calls, synthetic host controller ownership,
hidden/silent preload, gameplay start, frozen simulation while paused, resume,
Back press/release debounce through the real event handler, and native process
switching/cleanup. Volley names are checked on its winning-side score screens,
where the game actually displays them. Its feature results can fail independently.
Physical controller ownership still requires hardware testing; synthetic frames
and roster assertions are not proof of hardware behavior.

## Running it

From the repository (Python 3.10+):

```sh
python scripts/package-love-party.py --output dist/party
cargo build --locked -p gamenight-certify
python scripts/game-contract.py --output dist/contract --pack dist/party \
  --love /path/to/lovec --certifier target/debug/gamenight-certify
python scripts/game-contract.py --gate --output dist/contract --pack dist/party
```

On Windows, use `.exe` for the certifier. Inventory-only runs need no game runtime:
`python scripts/game-contract.py --output dist/inventory`.

`gamenight-certify GAME --report report.json -- COMMAND ...` exports protocol-only
JSON, including failures. It no longer calls an automated-only pass “party-ready”.
Manual questions are explicitly untested in that report, including CI runs.

## CI and publication

The LÖVE workflow runs on every main push and PR, including protocol, SDK, host,
catalog and test changes. It uploads Windows evidence and puts the matrix in the
Actions summary. The main workflow tests the gate and publishes the full catalog
inventory. The Linux render smoke test is separate; a Windows pass is never reused
as Linux or macOS proof. Windows CI installs checksum-pinned Mesa beside its test
runtime because hosted runners expose only OpenGL 1.1. OpenAL uses its null output
device in CI; source playback and muting are observed, not speaker audibility.
Neither test driver is shipped in the installer. The synthetic host drains game
replies, as the production daemon does, and kills its own process tree on timeout
while retaining failure logs.

The Windows publication workflow calls the same LÖVE workflow at the same revision,
downloads that run's packages and evidence, and runs the strict gate **before**
creating the release draft. PR builds remain usable for development even when
features are untested. Publication fails on any missing game, required untested
feature, failed mandatory/claimed check, stale commit, wrong platform, changed requirements, changed
package, or missing/modified evidence. There is no override for a catalog label.

The matrix covers the whole catalog. The Windows game release gate covers every
playable Windows catalog game, and requires an exact package match. The lobby
(host) and SDK example have explicit roles in `game-policies.json`; they are not
game downloads. A macOS-only download is not certified by a Windows run. These
rows remain untested, with no Windows rating credit. A new Windows game, missing
package, or extra unverified package still blocks publication.

## Extending coverage

Add a narrowly scoped runner that executes the actual packaged game. Record a
feature as passed only after it observes that feature, retaining logs/artifacts.
The existing `run_games` adapter handles LÖVE; native/Godot games need their own
artifact runner. Unavailable sources stay untested until their tested package is
supplied. Volley Trouble is part of the public shared LÖVE package.
Use a distinct feature when a unit test covers only part of a hardware behavior;
do not relabel an entire shared test suite as proof of every game feature.

When a requirement changes, change `requirements.json`. Old reports then fail the
gate automatically. Add a regression to `scripts/test-game-contract.py` for every
new way an incomplete integration could accidentally be accepted.

Contract v2 separates player-name sync, skin/clothing colour sync, and drawn face/hat sync. Previous combined appearance evidence does not satisfy any of these independently.

## Grouped ratings (contract v4)

The numeric catalog score runs from 0 to 5. It counts the eleven essential checks
and three independent personalisation checks: names, colours and faces. Each
verified check has equal weight. Party extras do not affect the score.

The playability label is separate: all essentials must pass for Ready to play.
A failing essential check means Integration issues. Partial or missing proof
remains visible. Development, dirty-worktree or unmatched-build results do not
increase the verified score or playability label.

Start, resume and switching are distinct from a handshake. Old aggregate lifecycle
or appearance evidence cannot satisfy granular checks. The source of truth for
groups and counts is `contract/requirements.json`.

`contract/game-policies.json` records first-party ownership and explicit feature
claims. First-party games require personalisation as well as essentials for
release. Claiming an optional feature also makes its passing proof mandatory.
Unclaimed optional failures remain visible but do not block compatibility.
Changes to requirements or policy invalidate release reports. The registry is
explicit: ownership is not guessed from a developer's display name.

## Continuous play

`gameplay.continuous` is essential. Round endings do not end a host session.
Games show their results briefly (normally three seconds) and start a fresh round
in the same session with the current roster and settings. Pause freezes both the
simulation and this results countdown. `finished` is an optional round notification;
it must not hide the window, request the lobby or advance the playlist.
Back/Select opens the lobby and pauses; Resume continues the same round or results.
Play next explicitly switches games. Skip only replaces the upcoming game.
The host retains the preloaded next session across round notifications, even with
no seated human players. Test multiple round endings and a pause during results.
