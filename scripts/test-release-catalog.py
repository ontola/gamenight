"""Ensure a release cannot silently omit native games or ship stale metadata."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_catalog", Path(__file__).with_name("check-release-catalog.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class CoverageTests(unittest.TestCase):
    def test_missing_native_and_stale_url_block_release(self):
        with tempfile.TemporaryDirectory() as directory:
            source, packaged = Path(directory) / "source", Path(directory) / "packaged"
            source.mkdir()
            packaged.mkdir()
            love = {"id": "love-game", "downloads": {"windows": {"url": "https://example.com/game.love"}}}
            native = {"id": "native-game", "downloads": {"windows": {"url": "https://example.com/game.zip"}}}
            for target in (source, packaged):
                (target / "love-game.json").write_text(json.dumps(love))
            (source / "native-game.json").write_text(json.dumps(native))
            with self.assertRaisesRegex(ValueError, "native-game"):
                check.check_coverage(source, packaged, "windows")
            (packaged / "native-game.json").write_text(json.dumps(native))
            self.assertEqual(len(check.check_coverage(source, packaged, "windows")), 2)
            native["downloads"]["windows"]["url"] = "https://example.com/old.zip"
            (packaged / "native-game.json").write_text(json.dumps(native))
            with self.assertRaisesRegex(ValueError, "changed=.*native-game"):
                check.check_coverage(source, packaged, "windows")


if __name__ == "__main__":
    unittest.main()
