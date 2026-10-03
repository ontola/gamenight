import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReleaseTests(unittest.TestCase):
    def test_catalog_preserves_metadata_and_native_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog, pack = root/'catalog', root/'pack'
            catalog.mkdir(); pack.mkdir()
            (pack/'game.love').write_bytes(b'certified bytes')
            native = {'url': 'https://example.org/native.zip', 'sha256': 'abc', 'entrypoint': 'game.exe'}
            entry = {'id': 'game', 'cover': 'art', 'downloads': {'windows': {'entrypoint': 'game.love', 'runtime': {'id': 'love'}}, 'linux': native}}
            path = catalog/'game.json'
            path.write_text(json.dumps(entry))
            load('prepare-release-catalog').prepare(catalog, pack, '0.2.123')
            result = json.loads(path.read_text())
            self.assertEqual(result['cover'], 'art')
            self.assertEqual(result['downloads']['linux'], native)
            self.assertEqual(result['downloads']['windows']['runtime'], {'id': 'love'})
            self.assertIn('/v0.2.123/', result['downloads']['windows']['url'])
            (pack/'game.love').unlink()
            with self.assertRaises(ValueError):
                load('prepare-release-catalog').prepare(catalog, pack, '0.2.124')

    def test_incomplete_release_cannot_be_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = load('release-manifest')
            with self.assertRaises(ValueError):
                module.manifest(root, '0.2.1', 'a'*40, '123')
            for name in ('GameNight-Setup.exe', 'GameNight.dmg', 'catalog.tar.gz', 'game-contract-windows.tar.gz'):
                (root/name).write_bytes(name.encode())
            result = module.manifest(root, '0.2.1', 'a'*40, '123')
            self.assertEqual(len(result['sha256']), 4)
            self.assertEqual(result['run_id'], 123)
            (root/'Another-Setup.exe').touch()
            with self.assertRaises(ValueError):
                module.manifest(root, '0.2.1', 'a'*40, '123')


if __name__ == '__main__':
    unittest.main()
