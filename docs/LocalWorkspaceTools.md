# Local workspace tools

This migration keeps the existing iSH and native runtime paths unchanged and adds an additive local-workspace path:

- `workspace_read` reads UTF-8 files from a device workspace.
- `workspace_edit` performs an exact, bounded replacement after the model has read the file. It uses the existing coordinated `FileToolIO` implementation and never invokes a shell.
- `workspace_analyze` inventories source files and reports TODO/unsafe-pattern hints, Makefile/control readiness and SDK 26 visibility. It is read-only.
- `workspace_git` provides status, diff, log, branch and explicit commit operations. Credentials are not read or stored by the tool.

The native build workbench now exposes ordinary LLVM optimization (`-O0`, `-Os`, `-O2`, `-O3`) separately from OLLVM obfuscation, and displays phase/progress updates from the existing build stream.

## iPhoneOS 26.0 SDK

The reference project's SDK is about 275 MB unpacked. It is therefore not duplicated into the application source or runtime bundle. Import the unpacked `iPhoneOS26.0.sdk` folder from Files into the native Theos root through the workbench. The app validates `SDKSettings.plist`, stages the copy, and uses `SDKVERSION=26.0` only when the SDK is present. The default remains 16.4.

No runtime executor, offload bridge, signing, or shell behavior is changed by these additions.
