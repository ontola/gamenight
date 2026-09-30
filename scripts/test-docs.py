import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("docs", Path(__file__).with_name("build-docs.py"))
docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docs)


class DocumentationTests(unittest.TestCase):
    def test_pages_links_and_generated_routes(self):
        output = docs.outputs()
        self.assertEqual(len(output), len(docs.PAGES) + 1)
        for page in docs.PAGES:
            html = output[docs.ROOT / "web" / docs.filename(page["slug"])]
            self.assertIn('aria-label="Documentation"', html)
            self.assertIn('/web/shell.js', html)
            self.assertIn('aria-current="page"', html)
            self.assertIn('Edit this page', html)

    def test_source_drift_changes_output(self):
        page = next(p for p in docs.PAGES if p["slug"] == "rust")
        before = docs.render(page)[0]
        original = docs.source
        with patch.object(docs, "source", side_effect=lambda p: original(p) + ("\n// API changed\n" if p == "crates/gamenight-sdk/src/lib.rs" else "")):
            self.assertNotEqual(before, docs.render(page)[0])

    def test_missing_excerpt_markers_fail(self):
        with self.assertRaisesRegex(ValueError, "moved or disappeared"):
            docs.expand('::: source rust crates/gamenight-sdk/src/lib.rs "missing marker" "end"', set())

    def test_broken_page_and_heading_links_fail(self):
        original = docs.source
        for link in ["/docs/missing", "/docs/faces#missing-heading"]:
            with patch.object(docs, "source", side_effect=lambda p: original(p) + (f"\n[Bad link]({link})\n" if p == "docs/site/overview.md" else "")):
                with self.assertRaisesRegex(ValueError, "Broken docs link"):
                    docs.outputs()

    def test_paths_cannot_escape_repository(self):
        with self.assertRaisesRegex(ValueError, "invalid documentation source"):
            docs.source("../not-ours.md")


if __name__ == "__main__":
    unittest.main()
