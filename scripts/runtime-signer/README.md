# OpenMinis runtime signer

This directory contains the independently built `codex-sign` adapter. It uses
public source APIs from fixed TrollStore fastPathSign and ChOma commits; it does
not copy the attached MT helper or depend on MT authorization hooks.

## Build

Run on macOS with Xcode and an iPhoneOS SDK:

```sh
scripts/build_runtime_signer.sh \
  --output build/runtime-signer/codex-sign
```

The script clones TrollStore at
`88424f683b2a08f34a3f88985f790f97d84ce1df`, verifies its ChOma submodule at
`964023ddac2286ef8e843f90df64d44ac6a673df`, downloads OpenSSL 3.5.9 and checks
SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`,
then builds an iOS arm64 static `libcrypto.a` and the signer. The build emits a
provenance JSON and a complete source-assets archive beside the work tree.

The resulting executable is not checked into `Configs/Helpers`. Staging it in
an app requires a successful macOS build and device validation first. The
workflow checks syntax, source pinning, iOS platform/architecture, and host
library absence; those checks do not claim CoreTrust runtime success.

## CLI contract

```text
codex-sign [--adhoc-only] [--entitlements plist] file [file ...]
```

`--adhoc-only` calls `codesign_sign_adhoc` and never calls
`apply_coretrust_bypass`. Without that option, the adapter calls the real
CoreTrust path after ad-hoc signing. `--entitlements` must be a readable plist
whose root object is a dictionary. Multiple files are staged and signed before
any replacement is committed. A failed stage leaves every original untouched;
replacement uses same-directory rename and restores mode, uid and gid. Symlinks,
non-regular files and unsupported inputs are rejected.

The preferred arm64/arm64e slice is extracted through ChOma's
`fat_find_preferred_slice`; the output intentionally becomes a thin file and
other FAT slices are discarded, matching the fixed fastPathSign behavior. The
adapter is scoped to iOS 15+ because the upstream private signer API is not
available on every older iOS release. Build success alone is not proof that a
particular device/OS accepts the CoreTrust exploit.
