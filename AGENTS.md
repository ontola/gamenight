# UI flow previews

When implementing or materially changing a user-facing flow, capture screenshots
of the working flow and include them directly in the chat, alongside any preview
link. Include a phone-sized view when the flow supports mobile use. Use test data
and keep credentials and private user information out of screenshots.

This is the user's stated review preference from 30 September 2026.

# Integration documentation

The website docs are generated from `docs/site/pages.json`, its Markdown sources
and source excerpts. When changing a protocol, SDK, controller/face helper or
release contract, review the corresponding pages, then run
`python scripts/build-docs.py` and `python scripts/build-docs.py --check`.
Install `docs/site/requirements.txt` first. Do not edit generated `web/docs*.html`
or `web/docs-routes.rs`. A successful build does not verify prose or real hardware;
state adapter gaps and test limits explicitly. Keep the SDK READMEs pointing at
the canonical engine guides. Import the committed public web bundle into the
internal repo before building the cloud service.


# Store gameplay videos

Before creating, changing or publishing a five-second store video, read
[docs/gameplay-previews.md](docs/gameplay-previews.md). Require a varied montage
of quick, readable gameplay cuts; encoding and playback checks alone do not
meet the preview quality bar. Apply this when adding a playable catalog entry too.

# Game source boundaries

Keep game source outside this repository. LÖVE games live in
`ontola/gamenight-games`; both lobby implementations stay public here. Run
`python scripts/fetch-game-sources.py` before building docs or game packages.
CI uses the revision in `game-sources.json`. For development, explicitly set
`GAMENIGHT_GAMES_DIR` to the game checkout. Push game changes before updating
the pin and regenerating the docs. Never overwrite a dirty game checkout.
