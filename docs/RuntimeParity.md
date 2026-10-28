# Native runtime parity with MT-Agent 1.0.9 Lite

This change targets the **general-purpose runtime contract**, not MT's AI,
accounts, remote-policy service, Codex CLI/app-server or Code Mode.
Reference archive SHA-256 and exact disassembly evidence are recorded in
`MT-Runtime-Evidence.md`. Static analysis is evidence, not an on-device test.

## Restored contracts

- Native tools use a link-time checked C ABI from the iSH offload handler.
  `stdin/stdout/stderr` no longer form an Objective-C selector that stdio macros
  can silently rewrite. Exceptions cannot escape the offload into iSH.
- Child spawning resets signal masks/dispositions. TrollStore native execution
  configures persona 99 / override 1 / uid 0 / gid 0 using dynamically resolved
  Darwin APIs. Failed identity configuration is not called successful root
  execution. The application itself retains its original uid.
- Installation is staged, signed, checked, then committed. Manifest capability,
  archive path and install-record boundaries are checked before publishing
  tools. Old working installations survive failed updates.
- Installed runtime PATH/environment overlays are shared by direct tools and
  shell commands. Empty PATH entries (notably OLLVM) remain empty; installing
  an obfuscation compiler must not replace ordinary clang implicitly.
- Process waiting, UTF-8 output framing, timeout and inherited stdout cleanup
  have executable regression coverage, not only `swiftc -parse` checks.
- Codex is excluded by runtime id, handler and `codex.*` capabilities; renaming
  one field must not re-enable its agent. `codex-sign` is only a standalone
  signature utility; `lib/codex/*.js` in Node is native-compatibility code.

## Deliberate differences / not claimed as completed

MT's `ca-filetool` is an argv[0] multicall trampoline with MT-specific artifact
build authorisation. Its forkless packaging path also patches Theos makefiles.
Minis does not copy this binary, spoof MT remote authorisation or pretend that
setting `CA_THEOS_EMBEDDED=1` recreates those patches. It uses its own installed
Theos/core tools. Exact equivalence for every MT forkless recipe is **not yet
established**.

The Lite archive includes bash/signature helpers but omits the corresponding
source/build scripts promised in its notices. They are not silently published
in this source tree. `scripts/import_runtime_helpers.py` permits a local,
SHA-256-recorded import of only `bash.real`, `codex-sign`, CA data and notices.
Before redistributing those GPL executables, supply their corresponding source
and build scripts. Without a usable runtime shell and signature helper, an
ordinary checkout is not a guaranteed working TrollStore distribution.

## Reproducible checks

```sh
python3 -m unittest discover -s scripts/tests -p 'test_runtime_*.py' -v
python3 scripts/check_runtime_manifest.py
python3 scripts/check_xcode_project_files.py --strict
bash -n scripts/stage_app_helpers.sh
```

`Runtime contract` CI additionally compiles and **executes production**
`NativeCommandRunner.swift` and `RuntimeOffloadBridge.swift` on macOS with a
host-only toolchain stub. This verifies the C ABI, argv/fd/output forwarding,
exit/signal status, timeout, parallel waits and background pipe cleanup. It
**does not** establish iOS AMFI/TrollStore acceptance.

## Required device acceptance before saying “usable”

On a compatible TrollStore/jailbroken iOS device, install/update Theos, Node,
Python, core tools, build tools, reverse tools and OLLVM. Verify:

1. `minis-runtime --doctor` reports `path: c-abi-linked` (bridge-only scope).
2. Diagnostics runs a real shell plus `make --version`; inspect child uid,
   signature reports, SDK and dynamic-library paths.
3. `minis-runtime node -e 'console.log(process.version)'`, Python import test,
   git/curl HTTPS, cmake/ninja and reverse tools actually run.
4. Build a minimal Theos tweak and `.deb` in each supported target scheme;
   inspect Mach-O architecture/signatures and package contents.
5. Run OLLVM's shipped `share/ollvm/device-smoke.sh` and supported passes;
   `clang --version` alone does not verify obfuscation.
6. Fail/cancel an update and restart the app; the previous runtime must remain
   discoverable. Remove a runtime; its PATH entries and capabilities disappear.

No full on-device result is asserted until these checks are observed.
