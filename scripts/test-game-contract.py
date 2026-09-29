"""Regression tests for fail-closed contract release checks."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zipfile
import zlib

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

    def test_optional_features_do_not_block_unclaimed_third_party_games(self):
        self.rules['features']['pause'].update(required=False,group='personalisation')
        for status in ('untested','not_applicable','failed'):
            self.check['status']=status
            self.assertEqual(self.errors(),[])

    def test_first_party_personalisation_and_explicit_claims_require_proof(self):
        self.rules['features']['pause'].update(required=False,group='personalisation')
        self.check['status']='untested'
        for policy in ({'first_party':True,'claims':[]},{'first_party':False,'claims':['pause']}):
            policies={'version':1,'games':{'game':policy}}
            self.report['policies']=policies
            self.assertTrue(m.release_errors(self.report,self.entries,self.rules,'sha','windows',self.output,self.pack,policies))
        self.assertTrue(self.errors()) # changed policy must invalidate old evidence

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

    def test_host_and_example_inventory_are_not_game_releases(self):
        policies={'version':1,'games':{'lobby':{'role':'host'},'demo':{'role':'example'}}}
        self.entries.extend([{'id':'lobby','title':'Lobby'}, {'id':'demo','title':'Demo'}])
        extras=m.new_report(self.entries[1:],self.rules,'sha','windows')['games']
        self.report['games'].extend(extras)
        self.report['policies']=policies
        self.assertEqual(m.release_errors(self.report,self.entries,self.rules,'sha','windows',self.output,self.pack,policies),[])
        self.assertEqual(extras[0]['checks']['pause']['status'],'untested')

    def test_other_platform_inventory_does_not_claim_windows_certification(self):
        entry={'id':'mac-game','title':'Mac game','downloads':{'mac':{'sha256':'a'*64}}}
        self.entries.append(entry)
        self.report['games'].extend(m.new_report([entry],self.rules,'sha','windows')['games'])
        self.assertEqual(self.errors(),[])
        entry['downloads']['windows']={'sha256':'b'*64}
        self.assertTrue(self.errors())

    def test_extra_package_or_missing_platform_game_blocks_release(self):
        (self.pack/'extra.love').write_bytes(b'unverified')
        self.assertTrue(self.errors())

    def test_native_download_is_not_an_installer_bundle_requirement(self):
        native={'id':'native', 'title':'Native', 'downloads':{'windows':{
            'entrypoint':'Native.exe', 'sha256':'a'*64}}}
        self.entries.append(native)
        self.report['games'].extend(m.new_report([native],self.rules,'sha','windows')['games'])
        self.assertEqual(self.errors(), [])
        (self.pack/'extra.love').write_bytes(b'unverified')
        self.assertTrue(self.errors())

    def test_spaceracer_probe_only_credits_observed_features(self):
        archive=self.root/'spaceracer-windows.zip'
        with zipfile.ZipFile(archive,'w') as packed:
            packed.writestr('SpaceRacer.exe',b'engine')
            packed.writestr('SpaceRacer.pck',b'game')
        features={key:{'required':False} for key in (
            'protocol.handshake','gameplay.start','gameplay.pause','gameplay.resume',
            'input.identity','process.disconnect','profile.identity','profile.face',
            'profile.colors','presentation.prewarm','presentation.frame','gameplay.continuous',
            'party.settings','party.round_end')}
        report=m.new_report([{'id':'spaceracer','title':'SpaceRacer'}],
                            {'version':1,'features':features},'sha','windows')
        entry={'id':'spaceracer','downloads':{'windows':{'sha256':m.digest(archive)}}}
        source=self.root/'source'
        (source/'tests').mkdir(parents=True)
        (source/'tests/integration.py').write_text('def wait(read, predicate, timeout=15):\n    pass\n')
        def fake_check(cmd,env,log,timeout):
            log.write_text('PASS')
            if any('test-spaceracer-frame.py' in part for part in cmd):
                Path(cmd[cmd.index('--capture')+1]).write_bytes(b'capture')
            return True
        with mock.patch.object(m,'catalog',return_value=[entry]), mock.patch.object(
            m.subprocess,'check_output',side_effect=['c5bb5eb9eb05a1a3dc3273453a5f1e49e36edfcb\n','']), mock.patch.object(
            m,'run_check',side_effect=fake_check):
            m.run_spaceracer(report,archive,source,self.output,window_probe=True)
        game=report['games'][0]
        self.assertEqual(game['artifact_sha256'],m.digest(archive))
        self.assertEqual(game['checks']['profile.face']['status'],'passed')
        self.assertEqual(game['checks']['presentation.prewarm']['status'],'passed')
        self.assertEqual(game['checks']['presentation.frame']['status'],'passed')
        self.assertEqual(game['checks']['party.settings']['status'],'passed')
        self.assertEqual(game['checks']['profile.colors']['status'],'passed')
        self.assertEqual(game['checks']['gameplay.continuous']['status'],'passed')
        self.assertEqual(game['checks']['party.round_end']['status'],'passed')
        self.assertEqual(len(game['checks']['presentation.prewarm']['evidence']),1)
        default=m.new_report([{'id':'spaceracer','title':'SpaceRacer'}],
                             {'version':1,'features':features},'sha','windows')
        with mock.patch.object(m,'catalog',return_value=[entry]), mock.patch.object(
            m.subprocess,'check_output',side_effect=['c5bb5eb9eb05a1a3dc3273453a5f1e49e36edfcb\n','']), mock.patch.object(
            m,'run_check',side_effect=lambda cmd,env,log,timeout: log.write_text('PASS') or True):
            m.run_spaceracer(default,archive,source,self.output)
        self.assertEqual(default['games'][0]['checks']['presentation.prewarm']['status'],'untested')
        self.assertEqual(default['games'][0]['checks']['presentation.frame']['status'],'untested')
        self.assertEqual(default['games'][0]['checks']['profile.colors']['status'],'passed')
        self.assertEqual(default['games'][0]['checks']['gameplay.continuous']['status'],'passed')

    def test_nested_evidence_uses_portable_paths(self):
        nested=self.output/'native'/'observations.json'
        nested.parent.mkdir()
        nested.write_text('{}')
        self.assertEqual(m.evidence(nested,self.output)['path'],'native/observations.json')

    def test_spaceracer_frame_check_rejects_blank_or_invalid_capture(self):
        spec=importlib.util.spec_from_file_location('spaceracer_frame',Path(__file__).with_name('test-spaceracer-frame.py'))
        frame=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(frame)
        capture=self.root/'capture.png'
        capture.write_bytes(b'not a screenshot')
        with self.assertRaises(ValueError):
            frame.png_pixels(capture)
        raw=(b'\0'+b'\0'*(640*3))*360
        def chunk(kind,data):
            return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
        capture.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',640,360,8,2,0,0,0))+
                            chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
        with self.assertRaisesRegex(ValueError,'blank'):
            frame.png_pixels(capture)

    def test_package_text_line_endings_do_not_change_artifact(self):
        spec=importlib.util.spec_from_file_location('packager',Path(__file__).with_name('package-love-party.py'))
        packager=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packager)
        a,b=self.root/'lf.zip',self.root/'crlf.zip'
        packager.write_zip(a,{'main.lua':b'return 1\n','image.png':b'\r\n'})
        packager.write_zip(b,{'main.lua':b'return 1\r\n','image.png':b'\r\n'})
        self.assertEqual(a.read_bytes(),b.read_bytes())

    def test_missing_executable_is_failed_with_evidence(self):
        log=self.output/'missing.log'
        self.assertFalse(m.run_check([str(self.root/'missing')],{},log))
        self.assertTrue(log.stat().st_size)


if __name__ == '__main__':
    unittest.main()
