# Publish a game

[Send us your game](/developers) when you want help getting into the catalog. Start with an email and a short message. You do not need to finish an integration before contacting us.

## Prepare a release

Once the integration is ready, use the [release workspace](/developers/releases). Provide a versioned build for one platform, its SHA-256, player limits and controls. Keep download URLs immutable so evidence continues to identify the tested file.

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
