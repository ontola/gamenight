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
SpaceRacer has a separate native runner. CI downloads the exact catalog ZIP,
checks its SHA-256, checks out the matching probe source at its fixed release commit,
and runs the packaged executable against its synthetic-host integration test.

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
For SpaceRacer, the packaged native probe covers protocol connection, start,
pause/resume, synthetic controller ownership, host disconnect, names and avatar
updates. Start opens the in-game pause menu; Back requests the host lobby. A separate headless test changes skin and clothing colours during play
and checks that only the matching player's face layer is rebuilt. It explicitly
disables extra AI racers so the probe observes only its two seated players. Another runs
an AI race through finish, then checks that the game starts a fresh race in the
same process and session. The optional
`--spaceracer-window-probe` runs the same pinned test
with a real window to check hidden and silent preparation, then captures and
inspects a gameplay frame from the packaged executable. The pinned probe also
verifies that live settings take effect on the next race. Use the window probe on a
Vulkan-capable Windows host. GitHub's hosted Windows runner lacks that GPU
support and stalls during renderer warmup, so CI leaves this check untested.
The hosted matrix does not verify a rendered SpaceRacer frame or physical pads;
the colour test checks the face layer's live data, not sampled display pixels.
Cross-game switching remains untested. Back/Select is
handled globally by the lobby, so the synthetic native host does not certify
that input path. A passing game-specific CI run is not blanket certification.

## Running it

From the repository (Python 3.10+):

```sh
python scripts/package-love-party.py --output dist/party
cargo build --locked -p gamenight-certify
python scripts/game-contract.py --output dist/contract --pack dist/party \
  --love /path/to/lovec --certifier target/debug/gamenight-certify
python scripts/game-contract.py --candidate-gate --output dist/contract --pack dist/party
```

On Windows, use `.exe` for the certifier. Inventory-only runs need no game runtime:
`python scripts/game-contract.py --output dist/inventory`.

`gamenight-certify GAME --report report.json -- COMMAND ...` exports protocol-only
JSON, including failures. It no longer calls an automated-only pass “party-ready”.
Manual questions are explicitly untested in that report, including CI runs.

## CI and publication

The LÖVE workflow runs on every main push and PR, including protocol, SDK, host,
catalog and test changes. It uploads Windows evidence and puts the matrix in the
Actions summary. A Linux job then verifies the downloaded Windows evidence and
package hashes with the candidate gate, catching path or packaging differences
before the installer finishes. The main workflow tests the gate and publishes the full catalog
inventory. The Linux render smoke test is separate; a Windows pass is never reused
as Linux or macOS proof. Windows CI installs checksum-pinned Mesa beside its test
runtime because hosted runners expose only OpenGL 1.1. OpenAL uses its null output
device in CI; source playback and muting are observed, not speaker audibility.
Neither test driver is shipped in the installer. The synthetic host drains game
replies, as the production daemon does, and kills its own process tree on timeout
while retaining failure logs.

The Windows publication workflow calls the same LÖVE workflow at the same revision,
downloads that run's packages and evidence, and runs the strict gate **before**
creating the release draft. PR builds may differ from the published downloads, but still require all mandatory
and claimed checks to pass. Publication fails on any missing game, required untested
feature, failed mandatory/claimed check, stale commit, wrong platform, changed requirements, changed
package, or missing/modified evidence. There is no override for a catalog label.

The matrix covers the whole catalog. The Windows installer release gate covers
every bundled `.love` catalog game and requires an exact package match. Native
games are downloaded separately; their artifact-specific probe results remain
in the matrix but do not become installer-bundle requirements. The lobby
(host) and SDK example have explicit roles in `game-policies.json`; they are not
game downloads. A macOS-only download is not certified by a Windows run. These
rows remain untested, with no Windows rating credit. A new bundled Windows game,
missing bundle package, or extra unverified bundle package blocks publication.

## Extending coverage

Add a narrowly scoped runner that executes the actual packaged game. Record a
feature as passed only after it observes that feature, retaining logs/artifacts.
The existing `run_games` adapter handles LÖVE. SpaceRacer's pinned native
adapter runs its released ZIP; other native/Godot games still need their own
artifact runner. Unavailable sources stay untested until their tested package
is supplied. Volley Trouble is part of the public shared LÖVE package.
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

## CI builds versus publication

Normal pull-request and main-branch CI uses `--candidate-gate` to verify the
newly built packages. It checks the commit, platform, source cleanliness,
catalog coverage, required features, artifact hashes and evidence hashes.
It allows those new packages to differ from the catalog's older published
version. A passing candidate is not release approval.

Publication still uses `--gate`, including in the Windows installer release
job. That additionally requires the tested artifact hashes to match the
catalog downloads. Update the release catalog and verify the corresponding
packages before publication. Never substitute `--candidate-gate` in a release
job.

## Your game's own tests

The contract checks cover the protocol. Your game also needs tests of its own
that a person would otherwise do by hand. What worked in our games:

- **A fake host.** A small script plays GameNight: it starts the game with
  `GAMENIGHT=1`, `GAMENIGHT_ADDR`, `GAMENIGHT_GAME_ID` and `GAMENIGHT_TOKEN`,
  answers `hello`, sends Prepare, waits for Ready, sends Start, controller
  frames, Pause, Resume and Dispose, and checks what the game did. The
  [Godot template](/docs/playbook) includes one in `tests/lifecycle.py`.
  Godot games also get a reusable one with the SDK:
  `addons/gamenight/fake_host.py`, Python standard library only and kept
  current by `sync.py --all`. It already does the next three points.

  ```python
  import sys; sys.path.insert(0, "addons/gamenight")
  from fake_host import FakeHost, frame, BUTTON_A

  with FakeHost("godot", game_id="my-game", path=".") as host:
      host.welcome()
      host.prepare([host.local_seat(0, "ada")], [{"id": "ada", "name": "Ada"}])
      host.start()
      host.hold(frame(BUTTON_A), 0.1)
      host.saw("jump Ada")   # a line your game printed with GAME_TRACE=1
  ```

  Pass `pack=` to run the exported game, or `command=` to start it another
  way (a packaged `.exe`, a launcher, a window). `host.disconnect()` plays a
  GameNight that goes away; `host.exit_code()` then checks the game quit
  cleanly. `HostClient` connects to a real GameNight as the overlay does.
- **Install Godot the same way everywhere.** In GitHub Actions use
  `ontola/gamenight/.github/actions/setup-godot@main` with your project's
  `version`; it verifies the download's sha256, works on Linux and Windows,
  and with `export-templates` installs the templates an export needs.
- **Keep sending frames.** Input older than 250 ms counts as released, so a
  test that holds a button must repeat the frame, about every 50 ms.
- **Listen on a free port.** Bind port 0 and pass the port in
  `GAMENIGHT_ADDR`, so a test never meets a real GameNight on the same machine
  and tests can run side by side.
- **Write the game's output to a file on Windows.** Godot on Windows writes
  stdout synchronously; an unread pipe blocks the game before it connects.
- **Trace what players would notice.** Print a line per event behind an
  environment variable (`GAME_TRACE=1`), and wait for those lines in the
  test. Pause state and menus are not visible over the protocol.
- **Run the exported game too.** Run the same test against the exported
  build in CI. Exports leave out excluded folders and non-resource files,
  which only shows there.
- **Bots play whole rounds.** Seeded bots playing a full match catch broken
  rules and stuck rounds. Count every mechanic and fail when one never
  happened.

Then test with real controllers and real people. Use the
[desktop checklist](desktop-integration-checklist.md): two profiles, reversed
connection order, a pad unplugged and plugged back in, repeated Back and
Resume, and several game switches. Tuning against bots alone misses how the
controls feel.
