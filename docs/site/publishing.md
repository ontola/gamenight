# Publish a game

Use the [developer portal](/developers) to add your game, upload builds, manage versions, edit your listing and create API keys. GameNight hosts accepted packages. You keep your own build tools, CI and source repository.

## Where your game's data lives

Keep two things in your repository and let GameNight production hold the rest:

- `gamenight.json` holds the facts about the game: id, title, tagline, developer, players, round length, tags, emoji, colour, requirements and links. Start it with `"$schema": "https://raw.githubusercontent.com/ontola/gamenight/main/catalog/schema.json"` so editors check it.
- `assets/gamenight/` holds the store media sources: `preview.mp4`, `preview.jpg`, `cover.png`, `icon.png`, `gameplay.png` and an optional `screenshots/` folder.

Builds, the store page, ownership and visibility live in production. `gamenight-publish.py push` (or the GitHub Action) sends builds and `gamenight-publish.py store` sends `gamenight.json` and the media. Do not put store text or media anywhere else. Hosts pick up a stable release from the hosted catalog; a new game needs no entry in the GameNight repository.

## Prepare a release

For a new game, sign in to the [developer portal](/developers) and choose **Add your game**. Free games can upload builds right away; ask for integration help from the game's **Help** tab. Existing catalog games need GameNight to register the correct owner once; matching a game name does not establish ownership.

1. Choose your game, then **Builds**.
2. Enter a version and platform. Upload a ZIP containing your exported executable and assets, or a standalone executable. Alternatively, import a direct HTTPS URL from S3 or another host. URL imports require the filename; signed URLs must remain valid throughout the import and must not redirect.
3. Set the executable path relative to the ZIP root, such as `Game.exe` or `Game.app/Contents/MacOS/Game`. For a bare file, use its filename. Add release notes.
4. After package verification, choose **Use as preview** and [playtest](#playtests) the exact build at real tables, then **Send for review** in the **Review** tab. Once approved, choose **Publish to players**.

Packages may be at most 512 MiB, with at most 2 GiB extracted from a ZIP. Use a ZIP for executables with DLLs, PCK files or other assets. LÖVE packages need a platform runtime registered by GameNight. GameNight copies URL imports into its own storage; gamers never depend on an expiring source URL.

A version identifies immutable bytes for one game and platform. Retrying the same version and checksum returns the same build. Changed bytes require a new version. Interrupted uploads can be retried. Choosing an older ready build for stable rolls back that platform without uploading again.

Previews are private to the owner, their game-scoped keys and tables with a tester seated. Public releases remain downloadable after rollback so cached catalogs still work. The portal shows upload failures and publishing activity.

## Playtests

Play your preview with real people before it reaches the store. In the portal, open your game's **Playtest** tab and create an invite link. Anyone who opens it and signs in with a GameNight account becomes a tester; you are always one yourself.

When you or a tester join a GameNight table with your phone, the host downloads the current preview build and shows it in the lobby under its own title, with "Test build" in its description. Everyone at that table can play it, testers or not. After the game, every phone at the table asks how it went: a thumbs up or down and an optional comment. Answers appear in the **Playtest** tab with the version and the player's name.

Every new preview, from CI or by hand, becomes the playtest build. A new invite link stops the old one from working; testers who joined stay until you remove them. A playtest build stays on a host's shelf until GameNight restarts, even after the tester leaves. When tables like it, send the build for review.

## Connect GitHub Actions

In **API keys**, create a named key for your game. Every key can upload builds and publish stable releases for that game, so keep it secret and revoke it when you no longer need it. Copy the secret immediately: it is shown once. Store it as `GAMENIGHT_API_TOKEN` in repository Actions secrets, or an environment secret when using a protected environment.

Add this step after packaging and testing:

```yaml
- name: Upload GameNight preview
  id: gamenight
  uses: ontola/gamenight@main
  with:
    token: ${{ secrets.GAMENIGHT_API_TOKEN }}
    game: my-game
    file: dist/my-game-windows.zip
    platform: windows
    entrypoint: Game.exe
    version: ${{ github.sha }}
    channel: preview
```

Pin the action to a reviewed commit SHA for reproducible CI. It calculates the checksum, streams the upload, promotes the preview and adds a portal link to the Actions summary. Outputs are `build-id`, `sha256` and `portal-url`.

Use `channel: stable` for automated public releases. That requires a publish-scoped key and GameNight distribution approval. Never provide secrets to pull-request code from untrusted forks. Build/test PRs without publishing; publish from trusted main or version-tag workflows.

Keys are restricted to one game. The portal lists expiry and last use. Create a replacement, update your CI secret, then revoke the old key. Revocation is immediate, including before an upload completes. Keys expire after 90 days by default; choose 30 days or up to one year. CI keys cannot create more keys or edit account details.

Games that build in one workflow and publish from a second `workflow_run` workflow can call the reusable workflow instead of copying these steps. It only uploads successful `main` or `v*` builds from your own repository:

```yaml
on:
  workflow_run:
    workflows: [Build and release]
    types: [completed]
permissions:
  contents: read
  actions: read
jobs:
  upload:
    if: vars.GAMENIGHT_PUBLISH_ENABLED == 'true'
    uses: ontola/gamenight/.github/workflows/publish-game.yml@main
    secrets:
      GAMENIGHT_API_TOKEN: ${{ secrets.GAMENIGHT_API_TOKEN }}
    with:
      artifact: my-game-windows   # artifact uploaded by the build
      game: my-game
      file: my-game-windows.zip   # path inside that artifact
      entrypoint: Game.exe
```

Pass the named secret explicitly when calling across repository owners:
`secrets: inherit` does not reach a reusable workflow in another organization. The reusable job selects your `gamenight` environment, where you can store the key.

The shared first-party pack uses a `gamenight-<game-id>` GitHub environment per game, each holding its `GAMENIGHT_API_TOKEN`. Native repositories use a `gamenight` environment. Set the repository variable `GAMENIGHT_PUBLISH_ENABLED=true` after registering ownership and configuring secrets. These workflows upload previews; CI does not silently replace a public release.

### CI pitfalls we hit

- **Every preview needs a new version.** A version identifies immutable bytes,
  so a rebuilt commit cannot reuse `${{ github.sha }}`. Add the run:
  `ci-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}`.
- **Pin what you run with your key.** Pin `ontola/gamenight` actions and
  reusable workflows to a reviewed commit, and check out a pinned copy of
  `scripts/gamenight-publish.py` for the store step. Keep both on the same
  commit, and update them together.
- **Pin and checksum your engine.** Download a fixed Godot version and check
  its SHA-256, in CI and in the export templates.
- **Test the exported build in CI.** Run your lifecycle test against the
  exported game, not only the editor project. Files under an excluded folder
  (such as `tests/`) and raw files outside the include filter are missing
  there, and the game only breaks in GameNight.
- **Agents often cannot push tags.** Trigger releases with a workflow input
  instead of a tag push.

## Other CI systems and local previews

[Download the Python uploader](/developers/gamenight-publish.py). It requires Python 3.11 or later and no third-party packages. Set `GAMENIGHT_API_TOKEN` in your shell or CI secret environment, then:

```sh
python gamenight-publish.py push --game my-game --file dist/game.zip --platform windows --entrypoint Game.exe --version 1.2.0 --channel preview --changelog "New arenas"
```

Download and verify a native preview without publishing it:

```sh
python gamenight-publish.py preview --game my-game --output .local/preview
```

Point `GAMENIGHT_LIBRARY` at the printed `shelf.json` when running a development host. On Windows the local launcher accepts this file through `-Shelf`. Downloading does not execute the game; start it through GameNight and test the [lifecycle](/docs/lifecycle). Runtime-based games use the registered LÖVE runtime alongside the `.love` file; the preview catalog includes the runtime checksum and entrypoint.

## Publishing API

Authenticate with `Authorization: Bearer YOUR_API_KEY`. Browser operations use the existing session and CSRF protection. Browser and CI requests use the same release service.

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/developer/games/{game}/builds` | Create or recover an immutable build |
| `PUT /v1/developer/builds/{build}/content` | Stream and verify package bytes |
| `POST /v1/developer/builds/{build}/import` | Copy a direct HTTPS URL into GameNight |
| `GET /v1/developer/builds/{build}` | Read state, checksum, size and processing error |
| `POST /v1/developer/games/{game}/releases` | Promote a ready build to preview or stable |
| `GET /v1/developer/games/{game}/preview-catalog` | Get your private preview manifest |
| `GET /v1/game-catalog` | Get public game updates |

Create a build with:

```json
{
  "version": "1.2.0",
  "platform": "windows",
  "filename": "game.zip",
  "entrypoint": "Game.exe",
  "sha256": "YOUR_64_HEX_SHA256",
  "changelog": "New arenas"
}
```

The response contains `id` and `state`. Upload to the content endpoint, or import with `{"url":"https://your-storage.example/game.zip"}`. For imports the expected checksum is optional; GameNight always records the actual checksum. Promote with `{"build":"BUILD_ID","channel":"preview"}`. Build states are `awaiting_upload`, `uploading`, `ready` and `failed`; release results are `preview_ready` or `live`. Invalid input returns 422, immutable-version conflicts return 409, and invalid/revoked keys return 401. Retry network failures using the same version and package.

## Catalog updates

New desktop builds refresh the trusted HTTPS publishing catalog in the background at launch and every 15 minutes. Downloads are checksum-verified and extracted into separate version directories. The shipped catalog and last valid cached update keep offline play available. Updates download during play; existing shelf entries keep their launch path until the next GameNight launch. Restart GameNight to activate updates. Failed downloads leave the previous installed version available.

Store metadata and artifact hashes use the promoted release. Uploads do not inherit old certification. Package verification checks hashes, ZIP safety and the entrypoint; it does not execute uploaded code or certify gameplay. Test controllers, player joining/leaving, return to lobby and continuous rounds against the actual release.

The first public release requires distribution approval. Subsequent updates can use the same approved game and publish-scoped key. **Store page** edits update title, description, player counts and website without rebuilding the app. Choose **Free** or **Paid**. Selling opens to the first developers soon. You set a price from €0.99 to €100 including VAT and keep 85% after VAT. GameNight is the seller and handles checkout, VAT, receipts and refunds; your share goes to your Stripe account with every sale. Players buy once, and one owner unlocks the game for the whole couch. Refunds are automatic within 14 days for buyers who played less than 2 hours. Ask about it from the portal's **Earnings** page.

Private repository access, AI-assisted code processing and game distribution each need agreement. Sharing a repository does not grant permission to distribute the game. Listing is free.

## Required gameplay video

Before publishing to players, upload a **five-second gameplay video** on the
Store page and save. Use MP4 or WebM, up to 32 MiB. It appears first and loops
silently; reduced-motion and data-saving preferences keep playback manual.
Screenshots, cover art and YouTube links are optional extras. A YouTube link does
not replace the gameplay clip. Drafts and private preview builds need no media.

GameNight measures the uploaded file on the server. It accepts 4.9–5.1 seconds
for frame and container rounding, and rejects unreadable or longer videos.
A live game must keep a clip: use **Replace gameplay video**, then save.
Show real gameplay and check the loop on a phone. Follow the
[gameplay preview guide](../gameplay-previews.md); duration validation does not
establish that the footage is good or representative.

### From the command line or CI

One command fills the store page with a publish key (the same key CI uses for
releases):

```sh
GAMENIGHT_API_TOKEN=gn_pub_... python3 gamenight-publish.py store
```

Run it in your game's folder. It reads `gamenight.json` (title, tagline,
developer, players, tags, round length, links) and uploads what it finds in
`assets/gamenight/`:

| File | Becomes |
| --- | --- |
| `preview.mp4` or `preview.webm` | the five-second gameplay clip |
| `preview.jpg` | the clip's poster |
| `cover.png` | portrait cover |
| `icon.png` | square icon |
| `gameplay.png` | TV screenshot, and the gallery image when there is no `screenshots/` folder |
| `screenshots/*.png` | gallery images, in name order |

Use `--manifest`, `--media`, `--video`, `--cover` (and so on) or a repeated
`--image` for other paths. Rerunning with the same files reuses the uploads and
costs no media quota. Pricing is never changed from the command line.

The script uses two endpoints, which accept a publish key or an owner session:

1. `POST /v1/developer/games/{game}/uploads` with the raw file bytes. The response
   contains `url` and `kind`. Invalid video returns `422` with an explanation.
   Uploading the same bytes again returns the same `url`.
2. `PUT /v1/developer/games/{game}/store` with any of `title`, `tagline`,
   `players_min`, `players_max`, `tags`, `match_minutes`, `homepage`, `source`,
   `cover`, `icon`, `screenshot`, `video`, `poster` and `images` (up to 9 URLs).
   Fields you leave out stay as they are; an empty string removes artwork or a
   link. `video` replaces the gameplay clip and `images` replaces the gallery
   images; YouTube trailers added in the portal are kept. The response says
   whether `preview_ready` is true.

The portal editor uses `PUT /v1/developer/games/{game}` with the full listing,
pricing and a `media` array. `GET /v1/developer/games/{game}` includes
`media.preview_ready` and `media.required_duration`. A stable release returns
`422` if no verified gameplay clip is saved. Existing approved clips remain valid.

Send the usual CSRF header for cookie authentication. Pasting an external video
URL or setting `duration: 5` yourself does not verify it, and a clip uploaded for
another game cannot satisfy this game's requirement.

## Optional artwork

Use a portrait cover for the next-game display, a square icon for game spines and a gameplay screenshot for the TV. These are separate assets. If artwork is absent, the title remains readable; a random icon is not a substitute for a cover.

```json
{
  "id": "my-game",
  "title": "My Game",
  "cover": "art/cover.png",
  "icon": "art/icon.png",
  "screenshot": "art/gameplay.png"
}
```

This is a local shelf artwork example. Downloadable catalog packages use the manifest format in the [catalog guide](../../catalog/README.md), including platform download hashes and entrypoints.

## Review the exact build

Run the [integration checks](/docs/testing) against the package players will download. Evidence from a different operating system or build does not count for this release. Missing checks remain untested.

The integration rating separates smooth play, player personalisation and optional extras. Faces are checked separately from colours and names. Staff review the build and distribution permission before publication; sending a message or submitting a build does not publish it automatically.
