import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sync_assets', Path(__file__).with_name('sync-dev-assets.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AssetSyncTests(unittest.TestCase):
    def test_incremental_edits_deletions_and_unmanaged_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, dest = Path(tmp)/'source', Path(tmp)/'dest'
            (source/'assets').mkdir(parents=True)
            (source/'assets/a.png').write_bytes(b'original')
            self.assertEqual(module.sync(source, dest)['copied'], 1)
            stamp = (dest/'assets/a.png').stat().st_mtime_ns
            self.assertEqual(module.sync(source, dest)['copied'], 0)
            self.assertEqual((dest/'assets/a.png').stat().st_mtime_ns, stamp)
            (source/'assets/a.png').write_bytes(b'changed!')
            self.assertEqual(module.sync(source, dest)['copied'], 1)
            (dest/'library.json').write_text('keep')
            (source/'assets/a.png').unlink()
            self.assertEqual(module.sync(source, dest)['removed'], 1)
            self.assertEqual((dest/'library.json').read_text(), 'keep')

    def test_manifest_cannot_remove_outside_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, dest = Path(tmp)/'source', Path(tmp)/'dest'
            source.mkdir(); dest.mkdir()
            outside = Path(tmp)/'precious'; outside.write_text('keep')
            (dest/'.dev-assets.json').write_text('{"../precious":"old"}')
            with self.assertRaises(ValueError): module.sync(source, dest)
            self.assertTrue(outside.exists())


if __name__ == '__main__': unittest.main()
