"""Regression tests for fail-closed contract release checks."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('contract', Path(__file__).with_name('game-contract.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pack = self.root/'pack'
        self.pack.mkdir()
        self.output = self.root/'evidence'
        self.output.mkdir()
        self.entries = [{'id':'game', 'title':'Game'}]
        self.rules = {'version':1,'features':{'pause':{'required':True}}}
        self.report = m.new_report(self.entries, self.rules, 'sha', 'windows')
        (self.pack/'game.love').write_bytes(b'game build')
        self.log = self.output/'proof.log'
        self.log.write_text('Observed frozen simulation and audio')
        self.report['games'][0]['artifact'] = 'game.love'
        self.report['games'][0]['artifact_sha256'] = m.digest(self.pack/'game.love')
        self.check = self.report['games'][0]['checks']['pause']
        self.check.update(status='passed', evidence=[m.evidence(self.log, self.output)])

    def errors(self):
        return m.release_errors(self.report, self.entries, self.rules, 'sha', 'windows', self.output, self.pack)

    def test_complete_current_evidence_passes(self):
        self.assertEqual(self.errors(), [])

    def test_untested_failed_and_not_applicable_cannot_hide_required_work(self):
        for status in ('untested','failed','not_applicable','typo'):
            self.check['status'] = status
            self.assertTrue(self.errors(), status)

    def test_new_catalog_game_blocks_release(self):
        self.entries.append({'id':'new', 'title':'New'})
        self.assertTrue(self.errors())

    def test_changed_binary_or_evidence_blocks_release(self):
        (self.pack/'game.love').write_bytes(b'new build')
        self.assertTrue(self.errors())
        self.report['games'][0]['artifact_sha256'] = m.digest(self.pack/'game.love')
        self.log.write_text('changed evidence')
        self.assertTrue(self.errors())

    def test_old_commit_or_wrong_platform_blocks_release(self):
        for key,value in [('commit','old'),('platform','linux'),('schema_version',99),('worktree_dirty',True)]:
            original=self.report[key]
            self.report[key]=value
            self.assertTrue(self.errors())
            self.report[key]=original

    def test_catalog_cannot_point_at_an_untested_download(self):
        self.entries[0]['downloads']={'windows':{'sha256':'0'*64}}
        self.assertTrue(self.errors())

    def test_missing_evidence_blocks_release(self):
        self.check['evidence']=[]
        self.assertTrue(self.errors())

    def test_evidence_cannot_escape_bundle(self):
        outside=self.root/'outside.log'
        outside.write_text('not bundled')
        self.check['evidence']=[{'path':'../outside.log','sha256':m.digest(outside)}]
        self.assertTrue(self.errors())

    def test_changed_contract_and_duplicate_games_block_release(self):
        self.report['requirements']=copy.deepcopy(self.rules)
        self.report['requirements']['version']=0
        self.assertTrue(self.errors())
        self.report['requirements']=self.rules
        self.report['games'].append(copy.deepcopy(self.report['games'][0]))
        self.assertTrue(self.errors())

    def test_inventory_does_not_claim_implementation(self):
        report=m.new_report(self.entries,self.rules,'sha','windows')
        self.assertEqual(report['games'][0]['checks']['pause']['status'],'untested')
        self.assertIsNone(report['games'][0]['artifact_sha256'])

    def test_missing_executable_is_failed_with_evidence(self):
        log=self.output/'missing.log'
        self.assertFalse(m.run_check([str(self.root/'missing')],{},log))
        self.assertTrue(log.stat().st_size)


if __name__ == '__main__':
    unittest.main()
