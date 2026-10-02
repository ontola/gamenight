import json
from concurrent.futures import Future
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from settings import Settings
from managed import Adapter


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        directory = self.root / 'world/gamenight'
        directory.mkdir(parents=True)
        (directory / 'status.json').write_text(json.dumps({'values': {'gravity': .6, 'jump': 1.2}}))
        self.settings = Settings(self.root)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.settings.close)

    def test_welcome_declares_actual_world_defaults(self):
        adapter = Adapter.__new__(Adapter)
        adapter.settings = self.settings
        adapter.send = Mock()
        adapter.receive({'type': 'welcome'})
        specs = adapter.send.call_args.args[0]['settings']
        self.assertEqual([s['default'] for s in specs], [60, 120])
        adapter.receive({'type': 'setting_changed', 'key': 'gravity', 'value': 125})
        self.assertEqual(self.settings.pending, {'gravity': 1.25})

    def test_rejects_invalid_values_without_changing_pending(self):
        self.assertTrue(self.settings.change('jump', 200))
        for key, value in [('other',100), ('jump',True), ('jump','50'), ('jump',1.5), ('jump',24), ('jump',201)]:
            self.assertFalse(self.settings.change(key, value))
        self.assertEqual(self.settings.pending, {'jump': 2})

    def test_all_live_controls_share_the_contract(self):
        from capabilities import SPECS, controls, valid
        values = {k: s['default'] for k, s in SPECS.items()}
        (self.root / 'world/gamenight/status.json').write_text(json.dumps({'values': values}))
        self.assertEqual(len(self.settings.specs()), 8)
        source = json.loads((Path(__file__).parent / 'capabilities.json').read_text())
        self.assertEqual(set(source['settings']), set(SPECS))
        for key, spec in SPECS.items():
            self.assertTrue(valid(key, spec['min']))
            self.assertTrue(valid(key, spec['max']))
            for bad in (True, '1', float('nan'), float('inf'), spec['min']-1, spec['max']+1):
                self.assertFalse(valid(key, bad))
            self.assertEqual(controls(values)[key]['unit'], spec['unit'])
            self.assertEqual(controls(values)[key]['applies'], 'live')
        self.assertTrue(self.settings.change('bounce', 15))
        self.assertEqual(self.settings.pending['bounce'], 1.5)
        self.assertTrue(self.settings.change('time_speed', 0))
        self.assertEqual(self.settings.pending['time_speed'], 0)

    def test_async_coalescing_never_blocks_controller_loop(self):
        worker = Mock(); first, second = Future(), Future()
        worker.submit.side_effect = [first, second]
        self.settings.worker.shutdown(); self.settings.worker = worker
        self.settings.change('gravity', 50)
        self.settings.tick(blocked=True)
        worker.submit.assert_not_called()
        self.settings.tick()
        self.settings.change('gravity', 75); self.settings.change('gravity', 125)
        self.settings.tick()  # unresolved future, returns immediately
        self.assertEqual(worker.submit.call_count, 1)
        first.set_result({'ok':True}); self.settings.tick()
        self.assertEqual(worker.submit.call_args.args[3], {'gravity': 1.25})
        second.set_result({'ok':True}); self.settings.tick()
        self.assertFalse(self.settings.pending)

    def test_busy_mailbox_retries_newest_value(self):
        worker = Mock(); pending = Future()
        pending.set_exception(RuntimeError('Another bridge command is in progress'))
        self.settings.worker.shutdown(); self.settings.worker = worker
        self.settings.future = pending; self.settings.inflight = {'gravity': .5}
        self.settings.change('gravity', 125)
        self.settings.tick()
        self.assertEqual(self.settings.pending, {'gravity': 1.25})
        self.assertEqual(self.settings.failures, 1)
        worker.submit.assert_not_called()
        with patch('settings.time.monotonic', return_value=self.settings.retry_at + 1):
            self.settings.tick()
        self.assertEqual(worker.submit.call_args.args[3], {'gravity':1.25})


if __name__ == '__main__': unittest.main()
