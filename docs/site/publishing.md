# Publish a game

Use the [developer portal](/developers/publishing) to upload builds, manage versions, edit your listing and create API keys. GameNight hosts accepted packages. You keep your own build tools, CI and source repository.

## Prepare a release

For a new game, start with a [submission](/developers/releases), or [contact us](/developers) for integration help. Then choose **Set up** in the publishing portal. Existing catalog games need GameNight to register the correct owner once; matching a game name does not establish ownership.

1. Choose your game, then **Versions**.
2. Enter a version and platform. Upload a ZIP containing your exported executable and assets, or a standalone executable. Alternatively, import a direct HTTPS URL from S3 or another host. URL imports require the filename; signed URLs must remain valid throughout the import and must not redirect.
3. Set the executable path relative to the ZIP root, such as `Game.exe` or `Game.app/Contents/MacOS/Game`. For a bare file, use its filename. Add release notes.
4. After package verification, choose **Use as preview**, test the exact build, then **Publish to gamers**.

Packages may be at most 512 MiB, with at most 2 GiB extracted from a ZIP. Use a ZIP for executables with DLLs, PCK files or other assets. LÖVE packages need a platform runtime registered by GameNight. GameNight copies URL imports into its own storage; gamers never depend on an expiring source URL.

A version identifies immutable bytes for one game and platform. Retrying the same version and checksum returns the same build. Changed bytes require a new version. Interrupted uploads can be retried. Choosing an older ready build for stable rolls back that platform without uploading again.

Previews are private to the owner and their game-scoped keys. Public releases remain downloadable after rollback so cached catalogs still work. The portal shows upload failures and publishing activity.

## Connect GitHub Actions

In **API keys**, create a named key for your game. Upload-only is the default; enable publishing permission only when CI should publish stable releases. Copy the secret immediately: it is shown once. Store it as `GAMENIGHT_API_TOKEN` in repository Actions secrets, or an environment secret when using a protected environment.

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
    secrets: inherit
    with:
      artifact: my-game-windows   # artifact uploaded by the build
      game: my-game
      file: my-game-windows.zip   # path inside that artifact
      entrypoint: Game.exe
```

The shared first-party pack uses a `gamenight-<game-id>` GitHub environment per game, each holding its `GAMENIGHT_API_TOKEN`. Native repositories use a `gamenight` environment. Set the repository variable `GAMENIGHT_PUBLISH_ENABLED=true` after registering ownership and configuring secrets. These workflows upload previews; CI does not silently replace a public release.

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

The first public release requires distribution approval. Subsequent updates can use the same approved game and publish-scoped key. **Store page** edits update title, description, player counts and website without rebuilding the app. Pricing intent and a proposed EUR price are saved privately; checkout, payouts and paid delivery are not enabled. Public releases remain free.

Private repository access, AI-assisted code processing and game distribution each need agreement. Sharing a repository does not grant permission to distribute the game. Listing is free; checkout and developer payouts are not implemented.

## Supply the artwork

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
