#!/usr/bin/python3
"""Static contract checks for the MT-style runtime recovery path.

The actual Mach-O spawn and TrollStore bundle-write checks run on iOS. These
cheap checks keep the source contract from regressing in CI: one managed root,
root persona on every native path, cwd/dylib setup for probes, and diagnostics
trace export.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(rel):
    return (ROOT / rel).read_text()

manager = text("src/ios/Agent/Runtime/DeveloperRuntimeManager.swift")
runner = text("src/ios/Agent/NativeBuild/NativeCommandRunner.swift")
verifier = text("src/ios/Agent/Runtime/RuntimeInstallVerifier.swift")
toolchain = text("src/ios/Agent/NativeBuild/NativeToolchain.swift")
diag = text("src/ios/Views/Settings/RuntimeDiagnosticsView.swift")
report = text("src/ios/Agent/Runtime/MTDiagnosticsReport.swift")
extractor = text("src/ios/Agent/Runtime/RuntimeTarGzExtractor.swift")
signing = text("src/ios/Agent/Runtime/RuntimeSigning.swift")

checks = {
    "bundle managed runtime root": 'appendingPathComponent("ManagedRuntimes"' in manager,
    "sandbox fallback": "applicationSupportRoot" in manager and "selectedRoot = applicationSupportRoot" in manager,
    "archive retained after verification": "keepVerifiedArchive = true" in manager,
    "managed root used by discovery": "DeveloperRuntimePaths.installedRoot" in toolchain,
    "root persona normal runner": "NativeSpawnIdentity.configure(&attr)" in runner,
    "root persona install probe": "NativeSpawnIdentity.configure(&attrs)" in verifier,
    "probe dylib path": 'DYLD_LIBRARY_PATH' in verifier,
    "probe working directory": "posix_spawn_file_actions_addchdir_np" in verifier,
    "diagnostics trace": "codexMTLog" in diag and "Codex-MT 运行诊断日志" in report,
    "tar root marker accepted": "normalizedEntryPath(full)" in extractor and "guard isDirectory, size == 0" in extractor,
    "tar traversal rejected": "part == \"..\"" in extractor and "hasPrefix(\"/\")" in extractor,
    "frameworks are adhoc signed": "declaredFrameworks" in signing and "code signature invalid" in signing,
    "framework probe paths": "root.appendingPathComponent(\"Frameworks\"" in verifier,
    "archive digest update detection": "sameArchive" in manager and "archiveSHA256.caseInsensitiveCompare" in manager,
    "update count UI": "updateCount" in text("src/ios/Views/Settings/DeveloperRuntimeSettingsView.swift"),
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("ok   " if ok else "FAIL ") + name)
if failed:
    raise SystemExit("failed checks: " + ", ".join(failed))
