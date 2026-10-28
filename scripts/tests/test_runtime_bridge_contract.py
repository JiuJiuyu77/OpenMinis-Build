#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('manifest_check', ROOT / 'scripts/check_runtime_manifest.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

class RuntimeBridgeContract(unittest.TestCase):
    def setUp(self):
        check.errors.clear(); check.warnings.clear()
        self.runtime = {'display_name': 'test', 'version': '1', 'handler': 'portable-v1',
            'archive_url': 'https://example.com/test.tar.gz', 'archive_sha256': 'a' * 64,
            'install': {'required_paths': ['bin/tool'], 'path_entries': ['bin'],
                'probe': {'executable': 'bin/tool', 'arguments': ['--version'], 'contains': 'ok'}}}
    def test_valid(self):
        check.check_runtime('test', self.runtime, set())
        self.assertFalse(check.errors)
    def test_path_escape(self):
        for key in ['path_entries', 'persistent_path_entries', 'sign_paths', 'sign_paths_without_entitlements']:
            with self.subTest(key=key):
                check.errors.clear()
                runtime = copy.deepcopy(self.runtime)
                runtime['install'][key] = ['../outside']
                check.check_runtime('test', runtime, set())
                self.assertTrue(check.errors)
    def test_codex_excluded_by_id_handler_or_capability(self):
        for key, runtime in [('codex', self.runtime), ('renamed', dict(self.runtime, handler='codex')),
                             ('renamed', dict(self.runtime, provides=['codex.app-server']))]:
            self.assertTrue(check.is_ignored(key, runtime))
        self.assertNotIn('codex', check.SUPPORTED_HANDLERS)
    def test_linked_bridge_no_objc_message(self):
        objc = (ROOT / 'src/ios/NativeOffloads/ConfigOffload.m').read_text()
        swift = (ROOT / 'src/ios/Agent/NativeBuild/RuntimeOffloadBridge.swift').read_text()
        self.assertIn('minis_runtime_run_tool(argc - 1, argv + 1,', objc)
        self.assertNotIn('[MinisRuntimeOffloadBridge runTool:', objc)
        self.assertIn('@_cdecl("minis_runtime_run_tool")', swift)
        self.assertIn('@objc(runTool:arguments:inputFD:outputFD:errorFD:)', swift)
        self.assertIn('@catch (NSException *exception)', objc)
    def test_helper_allowlist_has_no_agent_or_filetool(self):
        importer = (ROOT / 'scripts/import_runtime_helpers.py').read_text()
        self.assertIn("ALLOWED = ('bash.real', 'codex-sign')", importer)
        stage = (ROOT / 'scripts/stage_app_helpers.sh').read_text()
        self.assertNotIn('ln -sf ca-filetool', stage)
        self.assertIn('for name in bash.real codex-sign ldid;', stage)
    def test_staging_allowlist_and_data(self):
        import os
        import shutil
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'; scripts.mkdir()
            shutil.copy(ROOT / 'scripts/stage_app_helpers.sh', scripts)
            helpers = root / 'Configs/Helpers'; helpers.mkdir(parents=True)
            for name in ('bash.real', 'codex-sign', 'CodexApp', 'ca-filetool', 'cacert.pem'):
                (helpers / name).write_text(name)
            (helpers / 'Notices').mkdir()
            (helpers / 'Notices/Bash.txt').write_text('licence fixture')
            environment = dict(os.environ, BUILT_PRODUCTS_DIR=str(root / 'products'), WRAPPER_NAME='Minis.app', EXPANDED_CODE_SIGN_IDENTITY='')
            subprocess.run(['bash', str(scripts / 'stage_app_helpers.sh')], env=environment, check=True, capture_output=True)
            dest = root / 'products/Minis.app/Helpers'
            self.assertEqual((dest / 'sh').readlink().as_posix(), 'bash.real')
            self.assertEqual((dest / 'Notices/Bash.txt').read_text(), 'licence fixture')
            self.assertEqual((dest / 'cacert.pem').stat().st_mode & 0o777, 0o644)
            self.assertFalse((dest / 'CodexApp').exists())
            self.assertFalse((dest / 'ca-filetool').exists())

    def test_imported_files_are_not_committed(self):
        self.assertFalse((ROOT / 'Configs/Helpers/CodexApp').exists())
        self.assertFalse((ROOT / 'Configs/Helpers/ca-filetool').exists())

if __name__ == '__main__':
    unittest.main()
