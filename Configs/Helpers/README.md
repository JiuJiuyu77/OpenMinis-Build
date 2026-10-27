# Helpers — binaries that ship inside `<App>.app/Helpers/`

This directory is staged by `scripts/stage_app_helpers.sh` (add one Xcode "Run
Script" build phase that calls it, before the signing phase). Put the binaries
here; the directory is empty in a plain checkout and the script is a no-op.

| File | Why | Source |
|---|---|---|
| `bash.real` | The execution layer: a real bash (Darwin syscalls, `posix_spawn`), **not** the Linux busybox inside the iSH rootfs. Compiled binaries use it as `$SHELL`, so `make`, configure scripts and node-gyp work. | Build from bash upstream (`./configure --host=arm64-apple-ios`) or copy from a distribution build. |
| `codex-sign` | The signing layer, second half: rewrites the signature superblob (TeamID + cdhashes) on top of an ad-hoc signature. `ldid` alone leaves binaries that AMFI kills with `Bad executable` / `Killed: 9`. | TrollStore / FastPathSign lineage; see `ThirdPartyNotices` in that distribution before redistributing. |
| `ca-filetool` (optional) | Single-binary coreutils (`cat`, `cp`, `rm`, `tar`, …). The staging script creates the aliases next to it. | Same distribution as `bash.real`. |
| `ldid` (optional) | Only needed when the installed Theos runtime does not provide one; the signer looks in the runtime first. | Theos toolchain. |

Nothing here is required for the app to build or launch: without these files the
runtime layer reports `Ad-hoc signed only` / `no usable shell` and stays honest
about it.

Keep redistributable licenses in mind — check `THIRD_PARTY_LICENSES.md` when you
add a binary.
