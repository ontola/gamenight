# Automatic preview releases

A successful **Build and test** push run on `main` starts **Publish preview**.
It only proceeds if that exact commit is still the head of `main`. Pull requests
cannot publish. A newer commit supersedes an older build before publication.

The pipeline certifies the Windows game packages, builds the Windows installer,
then builds and smoke-tests the universal macOS app. Both installers use the same
release catalog, with immutable download URLs and checksums for the exact tested
LÖVE files. Native game downloads keep their pinned URLs and are installed in the
Windows packaging check.

The strict contract gate runs again before publication. The pipeline uploads all
files to a draft, then publishes the complete preview. Versions are `0.2.N`, where
`N` is the source CI run number. Retrying the same run cannot replace an already
published release. A failed build leaves the previous release available.

`release.json` records the source commit, publishing run, installer names and
artifact SHA-256 checksums. Website deployment consumes this manifest separately;
publishing on GitHub alone does not prove the website download has changed.

These remain previews. macOS uses ad-hoc signing, not Apple notarization. Windows
uses configured Azure signing when available. Automated tests do not replace
physical controller, GPU or clean-machine acceptance tests.

The manual Windows and macOS workflows remain available for diagnosis. Manual
Windows publication creates a draft for review.
