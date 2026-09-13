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
player artwork. These stronger requirements remain untested until instrumented
runners or hardware tests supply specific evidence. In particular, physical
controller ownership cannot be inferred from a roster JSON assertion.

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
as Linux or macOS proof.

The Windows publication workflow calls the same LÖVE workflow at the same revision,
downloads that run's packages and evidence, and runs the strict gate **before**
creating the release draft. PR builds remain usable for development even when
features are untested. Publication fails on any missing game, required untested
feature, failed check, stale commit, wrong platform, changed requirements, changed
package, or missing/modified evidence. There is no override for a catalog label.

**Current intentional consequence:** publication is blocked. We do not yet have
complete executable evidence for the entire catalog and all eight requirements.
This is exposed work, not a reason to silently mark those rows successful.

## Extending coverage

Add a narrowly scoped runner that executes the actual packaged game. Record a
feature as passed only after it observes that feature, retaining logs/artifacts.
The existing `run_games` adapter handles LÖVE; native/Godot games need their own
artifact runner. Unavailable/private sources (such as Volley Trouble in the internal
repository) stay untested in public CI until their tested package is supplied.
Use a distinct feature when a unit test covers only part of a hardware behavior;
do not relabel an entire shared test suite as proof of every game feature.

When a requirement changes, change `requirements.json`. Old reports then fail the
gate automatically. Add a regression to `scripts/test-game-contract.py` for every
new way an incomplete integration could accidentally be accepted.
