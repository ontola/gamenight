# GameNight branding

The sole editable logo is `web/icon.svg` at the repository root. Website navigation
and SVG favicons use it directly. Run `node scripts/generate-branding.cjs` with
Sharp available to regenerate ICO, Apple touch, legacy website PNG/SVG, and native
64px RGBA assets. Do not edit generated icons separately. Run with `--check` to
verify their hashes against `web/branding.json`; this check needs only Node.

The same ICO is embedded in the Windows executable and served as `/favicon.ico`.
The native window uses the generated RGBA pixels before lobby assets are loaded.
