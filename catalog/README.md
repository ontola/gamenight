# The GameNight Catalogue

An open, reviewable list of couch multiplayer games that work — or should
work — with [GameNight](../README.md). One JSON file per game in
[`games/`](games/), validated in CI, no build step: consumers read the files
directly.

The catalogue answers the questions a party asks before picking a game:
*how many of us can play? will it run on this machine? how big is the
download? does it actually speak the protocol, or is it on the wishlist?*

## The integration ladder

Every entry declares honestly where it stands:

| level | meaning |
|---|---|
| `certified` | speaks the protocol **and** passes [`gamenight-certify`](../crates/gamenight-certify) — party-ready |
| `integrated` | speaks the protocol; not (yet) certified |
| `adapter` | launchable by the daemon but silent — no protocol; transitions are kill-and-relaunch |
| `planned` | wishlist: metadata so the shelf can show it, no integration yet |

Climbing the ladder is the point: `planned` entries are invitations, and the
PR that moves a game to `certified` must include the harness output.

## Entry format

Every entry can start with `"$schema": "../schema.json"` — a
[JSON Schema](schema.json) generated from the Rust types in
[`gamenight-catalog`](../crates/gamenight-catalog), so editors catch typos
and missing fields as you type. It's generated, not hand-maintained: after
changing `CatalogEntry` or friends, run
`cargo run -p gamenight-catalog -- --write-schema` and commit the result —
`cargo test -p gamenight-catalog` fails the build if it's stale. The schema
only covers structure and types; cross-field rules (`players.max >=
players.min`, certified needing `protocol`, …) still live in `validate()`.

```json
{
  "$schema": "../schema.json",
  "id": "duck-game",
  "title": "Duck Game",
  "tagline": "Ducks. Guns. No mercy.",
  "developer": "Landon Podbielski",
  "players": { "min": 1, "max": 4, "best": 4 },
  "match_minutes": 3,
  "price": "paid",
  "tags": ["versus", "shooter", "chaos"],
  "emoji": "🦆",
  "color": "#ffb454",
  "cover": "https://…/cover.png",
  "integration": { "level": "planned" },
  "requirements": {
    "disk_mb": 200, "ram_mb": 1024,
    "cpu": "any dual-core", "gpu": "integrated is fine"
  },
  "links": { "steam": "https://store.steampowered.com/app/312530" },
  "downloads": {
    "linux": { "url": "https://…/duck-game-linux.tar.gz",
               "sha256": "…64 hex chars…", "size_mb": 180,
               "entrypoint": "duck-game-linux/duck-game" }
  }
}
```

Field rules (enforced by `cargo test -p gamenight-catalog`):

- `id` — lowercase kebab-case, must equal the filename (`games/<id>.json`),
  and matches the game id used on the wire.
- `players` — `min`/`max` are required; `best` is the count the game shines
  at. Don't lie: `max` is *couch* seats, not online lobby size.
- `price` — `free`, `pay_what_you_want`, or `paid`.
- `integration.level` — the ladder above. `certified` entries must state the
  `protocol` version and `certified_with` (harness version).
- `requirements` — approximate, honest figures. `disk_mb` installed size,
  `ram_mb` beyond the OS, `cpu`/`gpu` in plain words ("any dual-core",
  "integrated is fine"). A living-room PC is the target; when in doubt,
  round up.
- `downloads` — direct, stable URLs keyed by `linux` / `windows` / `mac`,
  each with a `sha256` (required for direct downloads — the daemon will
  refuse unverifiable installs) and `size_mb` (the download, not installed).
  Games sold through stores use `links` instead — never deep-link paid
  binaries. A `free` entry with a `downloads` URL for a given platform is
  **auto-installed in the background** by
  [`gamenight-installer`](../crates/gamenight-installer) — no click, no
  account — see [`CatalogEntry::auto_download_here`](../crates/gamenight-catalog/src/lib.rs).
  `pay_what_you_want`/`paid` entries are never silently installed, even with
  a `downloads` URL present (paid + `downloads` is itself rejected by
  `validate()`).
- `downloads.<platform>.entrypoint` — path to the runnable executable,
  relative to the extracted archive's root (e.g. `duck-game-linux/duck-game`).
  Required whenever the URL is an archive (`.tar.gz`/`.tgz`/`.zip` —
  [`Download::is_archive`](../crates/gamenight-catalog/src/lib.rs)); omit it
  for a bare-binary download, where the file itself is the executable. This
  is what turns a prewarmed install into a real, launchable shelf entry —
  the daemon resolves it into a [`LaunchSpec`](../docs/protocol.md) via
  `gamenight-installer`'s `InstalledGame::launch_spec`, no hand-written
  `shelf.json` entry required.
- `bundled` — for games that live in the GameNight repo itself (the demo
  games), a repo-relative path instead of downloads.
- `cover` — real cover art URL; `emoji` + `color` are the fallback poster
  the overlay generates.

### When upstream ships no download

Plenty of good couch games publish binaries only through a storefront's
JavaScript download flow, or tag releases with no attached assets at all.
That used to mean a permanent `planned` entry with `links` only. It doesn't
any more: **GameNight will host the build itself** so the game can be
installed like any other free entry, and `downloads.<platform>.url` points at
our storage instead of upstream's.

You don't have to do this to submit an entry — open the `planned` PR, say
that upstream has no fetchable binary, and we'll take it from there. What a
mirror commits us to, if you're proposing one:

- **A licence that permits redistribution.** Linking is not a copyright act;
  hosting the bytes is. MIT/Apache-2.0 is trivially fine. GPL/AGPL is fine
  and obliges us to offer the corresponding source for that same build. A
  NonCommercial licence, an unclear one, or none at all means we stay
  link-only no matter how good the game is — that's a hard no, not a
  negotiation.
- **A pinned, reproducible build.** Say which upstream tag it came from and
  what built it (engine version, export preset), so anyone can rebuild the
  artifact and check our sha256.
- **Upstream's own link stays in `links`.** A mirror is a convenience, never
  a replacement.
- **Someone keeps it current** when upstream releases.

Upstream is still the better fix where it's welcome — a PR adding a release
workflow to the game's own repo helps every launcher, not just this one, and
retires our mirror. Do that first when the project looks receptive; mirror
in the meantime.

## Submitting a game

Opening the PR is the easy part. A `planned` entry needs nothing but
metadata — no integration, no code, just enough that the shelf can show it
and the community can rally around getting it built. Here's the whole path,
start to merged.

### 1. Fork, clone, branch

```sh
git clone https://github.com/<you>/gamenight.git
cd gamenight
git checkout -b add-<your-game>
```

### 2. Write your entry

Copy the shape from [Entry format](#entry-format) above into
`games/<id>.json`. Starting at `planned` is fine — fill in what you know
(players, tagline, links) and leave the rest for later.

### 3. Validate locally

```sh
cargo test -p gamenight-catalog
```

This is the exact check CI runs on every PR: entry shape, cross-field rules
(`players.max >= players.min`, `certified` needing a `protocol` version, …),
and that the generated schema hasn't drifted. Fix everything it flags before
you push — a red CI check is the most common reason a PR sits unreviewed.

### 4. Climb the ladder (optional — do this now, or in a follow-up PR)

- **`integrated`** — your game must carry `gamenight.json` in its
  distribution and speak [the protocol](../docs/protocol.md). Read
  [the integration guide](../docs/integrating-your-game.md); most games take
  under an hour.
- **`certified`** — run `gamenight-certify <id> -- <your-binary>` locally
  and paste the full terminal output into the PR description. Reviewers read
  this instead of installing and playing your game themselves.
- **Direct downloads** — include the SHA256 (`sha256sum <file>`) and expect
  reviewers to verify it. Run `cargo run -p gamenight-installer` locally
  first — a free entry with a `downloads` URL for your platform gets
  fetched, hashed and extracted, so a bad URL, hash, or missing
  `entrypoint` fails on your machine instead of in review.

None of this blocks a `planned` PR going in today.

### 5. Open the PR

```sh
git add games/<id>.json
git commit -m "Add <Your Game> to the catalogue"
git push -u origin add-<your-game>
```

Open the PR against the GameNight repository's `main` branch, titled after the
game (`Add <Your Game> to the catalogue`). In the description:

- say which level you're claiming, and why
- paste the `gamenight-certify` output if you're claiming `certified`
- link to wherever the player counts / hardware requirements came from, if
  they're not your own testing

### What happens next

CI runs `cargo test --workspace` (every catalogue check included) plus
`fmt`/`clippy` across the whole repo — it has to be green before anyone
looks. A reviewer then checks the *honesty* of your claims — does the
`certified` output actually show every check passing? does the download
hash match? — not your prose. Small, single-game PRs review fastest; don't
bundle several games into one.

Metadata in this catalogue is contributed under [CC0](https://creativecommons.org/publicdomain/zero/1.0/);
game names and cover art remain their owners'.

## Browsing

```sh
cargo run -p gamenight-catalog          # table of everything
cargo run -p gamenight-catalog -- --level certified
```
