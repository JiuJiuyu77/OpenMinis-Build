#!/usr/bin/env python3
"""Source contracts plus an actual make-recipe fixture; no iOS execution claims.

Run: python3 scripts/tests/test_runtime_environment_contract.py -v
The make tests execute the Makefile literal extracted from production Swift.
These checks do not replace swiftc/Xcode typechecking or a real-device package.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'src/ios/Agent/NativeBuild'
CHAIN = (BUILD / 'NativeToolchain.swift').read_text()
HEALTH = (BUILD / 'RuntimeEnvironment.swift').read_text()
REPAIR = (BUILD / 'RuntimeRepair.swift').read_text()
PREF = (BUILD / 'ToolExecutorPreference.swift').read_text()


def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class RuntimeEnvironmentContract(unittest.TestCase):
    def test_general_tools_do_not_require_theos(self):
        overlay = section(CHAIN, 'private static func installedEnvironment()', 'private static func uniquePaths')
        self.assertIn('RuntimeEnvironmentOverlay.build(descriptor: descriptor, root: root)', overlay)
        self.assertIn('DeveloperRuntimePaths.installedRoot', overlay)
        self.assertIn('envelopeKey(id)', overlay)
        self.assertNotIn('guard let root = theosRoot', overlay)
        search = section(CHAIN, 'func searchPaths()', 'private static let toolLock')
        self.assertIn('Self.installedEnvironment().pathEntries', search)
        self.assertIn('prepareShims(sourceDirs: paths)', search)
        env = section(CHAIN, 'func environment(projectPath:', 'func findObfuscatingClang()')
        self.assertIn('env.merge(overlay.exports)', env)
        self.assertIn('searchPaths() + inheritedPaths', env)

    def test_no_agent_adopted(self):
        overlay = section(CHAIN, 'private static func installedEnvironment()', 'private static func uniquePaths')
        self.assertIn('!RuntimeDescriptor.isAgentIdentifier(id)', overlay)
        self.assertIn('descriptor.isSupportedRuntime', overlay)
        self.assertNotIn('codex-sign', overlay)  # signer is unrelated, not an agent/runtime

    def test_native_uses_no_private_forkless_helper(self):
        env = section(CHAIN, 'func environment(projectPath:', 'func findObfuscatingClang()')
        self.assertIn('env["CA_THEOS_EMBEDDED"] = "0"', env)
        self.assertIn('env["CA_THEOS_HELPER"] = nil', env)
        self.assertIn('env["CA_THEOS_PACKAGE_MODE"] = nil', env)
        self.assertNotIn('Helpers/theos-helper', env)
        self.assertNotIn('ca-filetool', env)

    def test_shell_discovery_has_one_candidate_implementation(self):
        discover = section(CHAIN, 'private static func discoverShell()', '// MARK: - 兼容层')
        self.assertIn('allShellCandidates().first', discover)
        candidates = section(CHAIN, 'static func allShellCandidates()', 'private static func shellPaths')
        for expected in ['Helpers/bash.real', 'bin/sh', 'runtimeBinaryDamage', 'resolvingSymlinksInPath']:
            self.assertIn(expected, candidates)
        self.assertIn('usr/bin/dash', CHAIN)

    def test_install_swap_invalidates_discovery_and_health(self):
        state = section(CHAIN, 'private static var runtimeState:', 'private static func refreshCachesIfNeeded')
        for field in ['installedRoot', 'recordsURL', 'manifest.json', '.modificationDate', '.systemFileNumber']:
            self.assertIn(field, state)
        self.assertIn('cachedTheos = nil', CHAIN)
        self.assertIn('cachedShell = nil', CHAIN)
        self.assertIn('cacheGeneration &+= 1', CHAIN)
        self.assertIn('lastGeneration == generation', HEALTH)
        self.assertIn('NativeToolchain.shared.generation == generation', HEALTH)
        self.assertIn('probeID == request', HEALTH)
        self.assertEqual(PREF.count('NativeRuntimeHealthMonitor.shared.invalidate()'), 2)

    def test_shims_retarget_and_remove_stale_links(self):
        shims = section(CHAIN, 'static func prepareShims(', '// MARK: - 环境')
        self.assertNotIn('shimDirCache', CHAIN)
        self.assertIn('destinationOfSymbolicLink', shims)
        self.assertIn('existing == resolved', shims)
        self.assertIn('if existing != nil', shims)
        self.assertNotIn('if fm.isExecutableFile(atPath: target.path) { continue }', shims)

    def test_sdk_directory_symlinks_and_numeric_versions(self):
        sdk = section(CHAIN, 'func findSDK()', '// MARK: - 工程识别')
        self.assertIn('Self.runtimeRoot(forTheos: root)', sdk)
        self.assertIn('isDirectory: &isDirectory', sdk)
        self.assertIn('options: .numeric', sdk)
        self.assertIn('env["SDKROOT"] = sdk', CHAIN)
        self.assertIn('env["THEOS_SDKROOT"]', CHAIN)

    def test_helpers_tls_and_writable_module_cache(self):
        for key in ['SHELL', 'CONFIG_SHELL', 'CA_THEOS_ZSH', 'CA_THEOS_MODULE_CACHE',
                    'CLANG_MODULE_CACHE_PATH', 'SSL_CERT_FILE', 'GIT_SSL_CAINFO']:
            self.assertIn('"' + key + '"', CHAIN)
        self.assertIn('subdirectory: "Helpers"', CHAIN)
        self.assertIn('where env[key]?.isEmpty != false', CHAIN)
        self.assertIn('.cachesDirectory', CHAIN)
        self.assertNotIn('env["BASH_ENV"]', CHAIN)  # no verified initialization script to source

    def test_health_runs_make_not_outer_printf(self):
        probe = section(HEALTH, 'nonisolated static func probe()', 'nonisolated static func classify(')
        self.assertIn('toolchain.findTool("make")', probe)
        self.assertIn('NativeCommandRunner.shellQuote(make)', probe)
        self.assertIn('--no-print-directory -f Makefile', probe)
        self.assertIn('"SHELL=$SHELL"'.replace('"', '\\"'), probe)
        self.assertIn('run(command: command', probe)
        self.assertNotIn('run(command: "printf', probe)
        self.assertIn('result.exitCode == 0 && result.output.contains', probe)
        self.assertIn('removeItem(at: probe)', probe)

    def test_integrity_does_not_require_one_archive_version(self):
        integrity = section(HEALTH, 'enum RuntimeIntegrity', '// MARK: - 运行时健康检查')
        self.assertNotIn('minimumSizes', integrity)
        self.assertIn('chain.shellPath', integrity)
        self.assertIn('chain.findTool("make")', integrity)
        self.assertIn('resolvingSymlinksInPath()', integrity)

    def test_repair_preserves_installed_runtime_identity(self):
        self.assertNotIn('health.failure.workaroundIsSandbox', REPAIR)
        self.assertIn('resolvedRoot.hasPrefix(supportPath + "/")', REPAIR)
        self.assertIn('NativeToolchain.runtimeRoot(forTheos: root)', REPAIR)
        self.assertIn('replaceItemAt(dest, withItemAt: staging)', REPAIR)
        self.assertIn('manager.remove(id)', REPAIR)
        self.assertIn('report.status == .skipped', REPAIR)
        self.assertIn('report.signedCount == 0', REPAIR)
        self.assertNotIn('canExecuteNative: true', REPAIR)

    @unittest.skipUnless(shutil.which('make'), 'host make unavailable')
    def test_real_make_recipe_requires_working_child_shell(self):
        literal = re.search(r'try ("all:.*?")\.write\(', HEALTH).group(1)
        recipe = json.loads(literal)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Makefile').write_text(recipe)
            args = ['make', '--no-print-directory', '-f', 'Makefile']
            ok = subprocess.run(args + ['SHELL=/bin/sh', 'all'], cwd=root, capture_output=True, text=True, timeout=8)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertIn('MINIS_RUNTIME_OK', ok.stdout)
            bad = subprocess.run(args + ['SHELL=/definitely/missing/minis-shell', 'all'], cwd=root, capture_output=True, text=True, timeout=8)
            self.assertNotEqual(bad.returncode, 0)
            self.assertNotIn('MINIS_RUNTIME_OK', bad.stdout)


if __name__ == '__main__':
    unittest.main()
