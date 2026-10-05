# Website documentation

`pages.json` defines sidebar order, page slugs and canonical Markdown sources.
Existing guides for faces, protocol and tests are rendered directly; do not keep
another website copy of their prose. Engine-specific guides live here.

```sh
python -m pip install -r docs/site/requirements.txt
python scripts/build-docs.py
python scripts/build-docs.py --check
python scripts/test-docs.py
```

Generated HTML and `web/docs-routes.rs` are committed for the public local server
and the cloud's pinned web import. Both servers use the same generated route map.
No Markdown parser runs in production. The docs use the shared Svelte navigation,
with persistent page views and page-scoped CSS. `/docs` is the entry point.

Use `::: source LANGUAGE PATH` to include an entire source file, or append two
JSON strings for inclusive start and exclusive end markers. Missing markers fail
the build. Paths are repository-relative. Watch additional implementation files
in the page manifest; their hashes appear in generated pages, so CI requires a
docs review after changes even if an excerpt itself is unchanged.

The compiler checks the Rust lifecycle example and C transport example in CI.
Godot adapter and lobby regressions run in the separate Godot integration job.
These tests do not certify third-party games or physical input. New APIs should
gain executable examples where the engine's test tooling permits it.

Watch the implementation a page actually documents. The publishing guide watches
the public uploader and Action; the private backend has its own documentation
contract check. Keep private operations out of the public guides, but explain
any developer-visible manual handoff or unavailable self-service feature.

Review prose before regeneration. A changed fingerprint signals work to review;
blindly regenerating it cannot make an outdated explanation correct.
