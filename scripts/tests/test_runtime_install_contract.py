#!/usr/bin/env python3
"""Offline SOURCE-CONTRACT checks, not Swift execution or iOS signing tests.
Run: python3 scripts/tests/test_runtime_install_contract.py
The macOS runtime_install_smoke.swift suite separately executes production Swift.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "src/ios/Agent/Runtime"


def source(name):
    return (RUNTIME / (name + ".swift")).read_text(encoding="utf-8")


class RuntimeInstallSourceContract(unittest.TestCase):
    def test_agent_filter_covers_id_handler_and_capabilities(self):
        manifest = source("RuntimeManifest")
        block = manifest.split("var isSupportedRuntime: Bool", 1)[1].split("var installationIssue", 1)[0]
        for fragment in ("isAgentIdentifier(id)", 'isAgentIdentifier(handler ?? "")',
                         "provides", "capabilities"):
            self.assertIn(fragment, block)
        manager = source("DeveloperRuntimeManager")
        self.assertIn("filter { $0.isSupportedRuntime }", manager)
        self.assertIn("if let issue = descriptor.installationIssue", manager)

    def test_manifest_validation_and_release_copy(self):
        text = source("RuntimeManifest")
        self.assertIn("manifest.schema == 4", text)
        self.assertIn("archiveSHA256.count == 64", text)
        self.assertIn('url.scheme?.lowercased() == "https"', text)
        if "func replacingRelease" in text:
            self.assertIn("install: install", text.split("func replacingRelease", 1)[1])
        else:
            self.assertNotIn("enum RuntimeVersionCatalog", text)
        self.assertIn("URL(string: archiveURL)?.path", text)

    def test_install_fields_fail_on_invalid_types(self):
        text = source("RuntimeInstallSpec")
        self.assertNotIn("try? container.decodeIfPresent", text)
        self.assertIn("paths.allSatisfy(RuntimePathPolicy.isRelativePath)", text)
        self.assertIn("persistentPathEntries + signPaths", text)

    def test_paths_resolve_symlinks_not_just_strings(self):
        text = source("RuntimeInstallSpec")
        policy = text.split("enum RuntimePathPolicy", 1)[1].split("// MARK:", 1)[0]
        self.assertIn('!path.hasPrefix("/")', policy)
        self.assertIn('contains("..")', policy)
        self.assertIn("canonicalURL(root)", policy)
        self.assertIn("canonicalURL(candidate)", policy)
        self.assertIn("destinationOfSymbolicLink", policy)
        self.assertIn("links <= 40", policy)
        self.assertIn('resolved.hasPrefix(basePath == "/" ? "/" : basePath + "/")', policy)
        self.assertIn("RuntimePathPolicy.containedURL(probe.executable", source("RuntimeInstallVerifier"))
        self.assertIn("RuntimePathPolicy.containedURL($0, in: root)", source("RuntimeSigning"))

    def test_sign_before_probe_then_commit(self):
        text = source("DeveloperRuntimeManager").split("private nonisolated static func performInstall", 1)[1]
        signing = text.index("RuntimeSigner.signRuntime")
        probe = text.index("RuntimeInstallVerifier.verify")
        swap = text.index("try fm.moveItem(at: scratch, to: target)")
        self.assertLess(signing, probe)
        self.assertLess(probe, swap)
        self.assertIn("try Task.checkCancellation()", text[probe:swap])
        self.assertIn("await manager.commit(record)", text[swap:])

    def test_cancellation_reaches_detached_and_deb_stages(self):
        text = source("DeveloperRuntimeManager")
        self.assertIn("withTaskCancellationHandler", text)
        self.assertIn("extraction.cancel()", text)
        self.assertIn("ZstdDecompressor.decompress(memberFile, to: tarFile, isCancelled: isCancelled)", text)
        self.assertIn("DebArchive.extract(data, from: archive, to: memberFile, isCancelled: isCancelled)", text)
        self.assertIn("if isCancelled() { throw CancellationError() }", source("DebArchive"))
        self.assertIn("if isCancelled() { throw CancellationError() }", source("ZstdDecompressor"))

    def test_download_preserves_prefix_and_checks_range(self):
        text = source("DeveloperRuntimeManager")
        self.assertRegex(text, r'if !fm.fileExists\(atPath: partial.path\)\s*\{\s*guard fm.createFile')
        self.assertIn('value(forHTTPHeaderField: "Content-Range")', text)
        self.assertIn("guard start == already", text)
        self.assertGreaterEqual(text.count("written > expectedSize + 1024 * 1024"), 2)
        self.assertIn('removeItem(at: archive.appendingPathExtension("part"))', text)

    def test_signer_staging_environment_and_bootstrap(self):
        text = source("RuntimeSigning").split("static func signArtifacts", 1)[0]
        self.assertIn("locateLdid(stagingRoot: root)", text)
        self.assertIn("signingEnvironment.merge(overlay.exports)", text)
        self.assertIn('codex-sign is required for native runtime installation', text)
        self.assertIn('let batchSize = 16', text)
        self.assertIn('signBatches(noEnt.targets, with: nil)', text)
        self.assertIn('signBatches(privileged.targets, with: plistURL)', text)
        self.assertIn('mode: "codex-sign-coretrust"', text)
        self.assertIn("Declared signing target is missing", text)
        self.assertIn("Cannot write signing entitlements", text)
        self.assertIn("resolvingSymlinksInPath()", text)

    def test_spawn_root_identity_cwd_and_fd_ownership(self):
        text = source("RuntimeInstallVerifier")
        identity = text.index("NativeSpawnIdentity.configure(&attrs)")
        spawn = text.index("let spawnStatus = posix_spawn")
        self.assertLess(identity, spawn)
        self.assertIn("guard identityStatus == 0", text[identity:spawn])
        self.assertIn('dlsym(handle, "posix_spawn_file_actions_addchdir_np")', text)
        self.assertIn('addWorkingDirectory(&fileActions, workingDirectory)', text)
        self.assertIn('else { return ENOTSUP }', text)
        self.assertIn("posix_spawnattr_getflags(&attrs, &flags)", text)
        self.assertIn("pipefds[0] = -1", text)
        self.assertIn("pipefds[1] = -1", text)
        self.assertIn("FD_CLOEXEC", text)

    def test_spawn_output_bounded_without_premature_close(self):
        text = source("RuntimeInstallVerifier")
        self.assertIn("max(0, (1 << 20) - data.count)", text)
        self.assertNotIn("if box.snapshot.count", text)
        self.assertIn("O_NONBLOCK", text)
        self.assertIn("readerStop.signal()", text)
        self.assertIn("ProcessInfo.processInfo.systemUptime", text)
        self.assertIn("if waited == -1", text)

    def test_gzip_bounded_output_and_final_member(self):
        text = source("RuntimeTarGzExtractor")
        self.assertIn("inflater.didSeeMemberEnd, inflater.isAtMemberEnd", text)
        self.assertIn("try consume(Data(buffer[0..<produced]))", text)
        self.assertNotIn("output.append(contentsOf: buffer", text)
        self.assertIn("if stream.avail_in == 0 && stream.avail_out > 0", text)
        self.assertIn("try restartForNextMember()", text)

    def test_tar_checksum_long_links_and_entry_boundary(self):
        text = source("RuntimeTarGzExtractor")
        self.assertIn("tar header checksum mismatch", text)
        self.assertIn('metadataIsLink = type == UInt8(ascii: "K")', text)
        self.assertIn("if let longLink { linkTarget = longLink }", text)
        self.assertIn("entry after tar terminator", text)
        self.assertIn("non-file tar entry has a payload", text)
        self.assertNotIn("try? fm.linkItem", text)
        self.assertIn("RuntimePathPolicy.containedURL(path, in: destination)", text)

    def test_environment_empty_path_is_not_overridden(self):
        text = source("RuntimeInstallSpec")
        self.assertIn('forKey: .pathEntries) ?? ["usr/bin", "bin"]', text)
        self.assertNotIn('for fallback in ["usr/bin", "bin"]', text)
        self.assertIn('exports["CA_RUNTIME_ROOT"] = root.path', text)
        self.assertIn("for entry in spec.persistentPathEntries", text)
        self.assertIn("RuntimePathPolicy.containedURL(entry, in: home)", text)
        self.assertIn('("DYLD_LIBRARY_PATH", ["usr/lib", "lib"])', text)
        self.assertIn("options: .numeric", text)

    def test_zstd_negative_cache_and_dead_structs_removed(self):
        text = source("ZstdDecompressor")
        self.assertIn("private static var cachedAPI: API?", text)
        self.assertNotIn("cachedAPI: API??", text)
        self.assertIn("apiLock.lock(); defer { apiLock.unlock() }", text)
        self.assertNotIn("struct ZstdInBuffer", text)
        self.assertNotIn("struct ZstdOutBuffer", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
