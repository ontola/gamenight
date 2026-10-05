# Publish a game

Use the [developer portal](/developers/publishing) to upload builds, manage versions, edit your listing and create API keys. GameNight hosts accepted packages. You keep your own build tools, CI and source repository.

## Prepare a release

For a new game, sign in and save a free-game draft in the
[release workspace](/developers/releases), or [contact us](/developers) for
integration help. Then choose **Set up** for the draft in the publishing portal.
You can upload private previews before submitting for distribution review.
Existing catalog games need GameNight to register the correct owner once;
matching a game name does not establish ownership.

1. Choose your game, then **Versions**.
2. Enter a version and platform. Upload a ZIP containing your exported executable and assets, or a standalone executable. Alternatively, import a direct HTTPS URL from S3 or another host. URL imports require the filename; signed URLs must remain valid throughout the import and must not redirect.
3. Set the executable path relative to the ZIP root, such as `Game.exe` or `Game.app/Contents/MacOS/Game`. For a bare file, use its filename. Add release notes.
4. After package verification, choose **Use as preview** and test the exact build.
   For a first release, complete [distribution review](#first-release-review)
   before choosing **Publish to gamers**.

Packages may be at most 512 MiB, with at most 2 GiB extracted from a ZIP. Use a ZIP for executables with DLLs, PCK files or other assets. LÖVE packages need a platform runtime registered by GameNight. GameNight copies URL imports into its own storage; gamers never depend on an expiring source URL.

A version identifies immutable bytes for one game and platform. Retrying the same version and checksum returns the same build. Changed bytes require a new version. Interrupted uploads can be retried. Choosing an older ready build for stable rolls back that platform without uploading again.

Previews are private to the owner and their game-scoped keys. Public releases remain downloadable after rollback so cached catalogs still work. The portal shows upload failures and publishing activity.

Builds are per platform: `windows`, `mac` or `linux`. Upload and test each platform
separately; publishing Windows does not update the Mac build. There is no separate
architecture selector, so choose and describe the architectures your package
supports. ZIP files must contain the playable export, not just source code. Test
without the editor installed. On macOS and Linux retain executable permissions;
check macOS signing and Gatekeeper on a clean machine as part of your own release.
The uploader does not sign or notarize builds for you.

## First release review

The release submission and package upload are separate records today. In the
release workspace, provide the version, platform, SHA-256, player limits,
controls and a playable HTTPS build link that the reviewer can access. Confirm
your right to submit it and submit the draft. Approval requires the checksum,
test report, controller/lobby checks and a recorded distribution agreement.

Use the private conversation to arrange build access and send report or artwork
links. Owner-only preview artifact links do not grant staff access; do not send
an API key to work around that. There is no automatic attachment transfer from
publishing to the submission. Staff can request changes before approving.

Once approved, publish the same tested package. Distribution approval permits
stable releases for the registered game; it does not turn tests green. Routine
updates use **Versions** or CI. Editing the original submission creates a new
review revision and revokes its publishing approval until staff approve again.
Use that route for changes that need renewed distribution review, not every
ordinary build upload.

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

With the [development host](/docs/first-game) installed, run from its checkout:

```sh
python scripts/run-local.py --lobby godot --godot godot --shelf .local/preview/shelf.json
```

Choose an output directory outside the extracted game. The preview command picks
your current OS by default; use `--platform windows`, `mac` or `linux` to download
another package, then test it on that platform. Keep the token in the environment,
not in your shelf file. No store account is needed for the earlier local-build test.

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

The portal cannot upload or edit artwork yet. Send staff links to your PNG cover,
icon and real gameplay screenshot in the private conversation, with the game ID
and permission to use them. For the embedded catalog, each PNG must fit within
1024 × 1024 and 256 KiB. Staff need to add the artwork to the registered publishing
metadata as well as any source catalog entry; putting images in your game ZIP
alone does not set the listing artwork. This is a manual handoff, not an upload
API. Optional gameplay videos should follow the
[preview guide](../gameplay-previews.md).

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

The integration rating counts essential play and the separate name, colour and
face checks. Optional extras are shown separately and do not increase the score.
See [getting verified results into the store](/docs/testing#store-verification).
There is no public evidence-upload API or automatic hosted certification job for
arbitrary third-party packages today. Share your reports for staff review; do not
expect an upload or a passing protocol test to change the rating automatically.
Sending a message or submitting a build does not publish it.
