# OpenMinis

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android-lightgrey.svg)](#beta-programme)

**Your private, on-device AI agent.**

OpenMinis brings leading models — Claude, GPT, Gemini and more — into a native
mobile experience, and gives them a real computer to work with: a full Linux
shell running on your device, browser automation, extensible skills, persistent
memory, and deep system integration.

It is free, and fully open source.

**We believe that in the age of AI, technical design and code are no longer
where a product's advantage lies. The best agent emerges from a tight feedback
loop with the people who use it — their expectations and their reports are
what converge on the product.**

Official website: **[openminis.app](https://openminis.app)**

<a href="https://apps.apple.com/app/id6759188481">
  <img alt="Download on the App Store" height="48" src="assets/badge-appstore.svg" />
</a>
&nbsp;
<a href="https://github.com/OpenMinis/OpenMinis/releases">
  <img alt="Get the APK on GitHub" height="48" src="assets/badge-android.svg" />
</a>

![Minis on iOS — deep research, chat, agent runtime, integrations, iCloud sync and granular permissions](assets/screenshots.png)

---

## What it does

| | |
|---|---|
| **Bring your own model** | Claude, GPT, Gemini and other providers, via your own API keys or account sign-in. |
| **A real Linux shell** | A sandboxed Alpine Linux environment runs on-device — the agent can install packages, run scripts, and work with real files. |
| **Device integration** | Health, Calendar, Reminders, Contacts, HomeKit, Bluetooth, Clipboard, Media, Alarms and more, exposed to the agent as tools. |
| **Browser automation** | The agent can browse and interact with the web on your behalf. |
| **Skills & memory** | Extensible skills plus persistent memory across sessions. |
| **Workspaces** | Organise work into separate contexts, addressable via `minis://workspace/`. |
| **Native offloads** | Heavy or platform-specific work is handed to native code instead of the sandbox. |

---

## What you can do with Minis

A few things people actually use it for:

- **Photograph a meal, log the nutrition** — Minis identifies the dishes, estimates
  calories and macros, and writes them to Apple Health.
- **Wake up to your timeline** — Shortcuts triggers Minis to fetch your X timeline,
  summarise it, synthesise speech, and play it as your alarm.
- **Turn group chatter into tasks** — pull messages from a Telegram group, extract
  bugs and action items, deduplicate them, and file them into Apple Reminders.
- **Mount your Obsidian vault** — research, clean up and write Markdown notes back
  into the vault as a normal workspace.
- **Share anything into a calendar event** — send a page or message to Minis via the
  iOS Share Sheet and it creates the event, time and place included.

**→ [OpenMinis/AwesomeMinis](https://github.com/OpenMinis/AwesomeMinis)** — a curated,
community-contributed collection of use cases and workflows across health,
productivity, research, finance and developer tooling.

---

## Skills

A **skill** is a folder with a `SKILL.md` file — instructions, and optionally scripts,
references and assets — that the agent loads on demand when a request matches it.
Metadata stays in context for triggering; the body and bundled resources load only
when the skill is actually used.

Minis has its own tool system, but it does not require skills written specifically
for it: **skills built for Claude, Codex, OpenClaw or Hermes Agent generally run in
Minis as-is.** Skills that have been adapted to Minis' tools simply run better —
they can reach the Linux shell, device integrations and native offloads directly.

**→ [OpenMinis/MinisSkills](https://github.com/OpenMinis/MinisSkills)** — skills
adapted for Minis alongside ones built for it from scratch, covering TTS, search,
media downloads, health analysis, cloud APIs and more.

---

## Press

> "the most impressive indie app I've seen in a while"
>
> — Federico Viticci, [**Open Minis Is the iOS Agent I Wish Siri AI Could Be**](https://www.macstories.net/reviews/open-minis-is-the-ios-agent-i-wish-siri-ai-could-be/),
> MacStories (July 2026)

> "在很大程度上实现甚至局部超越了 Apple Intelligence"
>
> — Ye Han, [**这可能是 iPhone 最强 Agent 软件，没有之一 丨Open Minis 入门指南**](https://zhuanlan.zhihu.com/p/2045570157783807562),
> 知乎 / Zhihu (June 2026)

> "可能是 iOS 端最强 AI Agent"
>
> — [**Open Minis：可能是 iOS 端最强 AI Agent**](https://www.appinn.com/open-minis/),
> 小众软件 / Appinn (March 2026)

---

## Beta programme

App Store releases can lag behind: every update waits on review, and we hold
builds back when stability warrants it. The TestFlight build is where fixes
and new features land first.

**→ [Join the TestFlight beta](https://testflight.apple.com/join/3BdkA5c3)**

On Android, the [releases page](https://github.com/OpenMinis/OpenMinis/releases)
always carries the latest APK.

---

## Developer Runtime (this fork)

This fork keeps the upstream app intact but adds a **Developer Runtime**
installer, so the on-device toolchain (Theos, OLLVM, CoreTools, ReverseTools,
BuildTools, Node, Python) can be downloaded, SHA-256 verified and installed from
**Settings → Developer Runtime** without shipping a 1 GB toolchain inside the
IPA.

| | |
|---|---|
| Manifest | `src/ios/Agent/Runtime/RuntimeManifest.swift` |
| Archive extractor (tar.gz) | `src/ios/Agent/Runtime/RuntimeTarGzExtractor.swift` |
| Archive extractor (.deb) | `src/ios/Agent/Runtime/DebArchive.swift` + `ZstdDecompressor.swift` |
| Installer | `src/ios/Agent/Runtime/DeveloperRuntimeManager.swift` |
| Settings screen | `src/ios/Views/Settings/DeveloperRuntimeSettingsView.swift` |

### Runtime Versions (aligned with MT Agent 1.1.0)

| Component | Version | Features |
|-----------|---------|----------|
| **Node.js** | 24.5.0 (recommended)<br/>18.20.4 (compatible) | npm 11.5.1, native module compilation (node-gyp + N-API), iOS arm64 optimized |
| **OLLVM** | Arkari LLVM 23.1.1 | String encryption (`--irobf-cse`), integer/float constant encryption (`--irobf-cie`/`cfe`), control flow flattening (`--irobf-fla`), arm64/arm64e support |
| **Theos** | adapter rev14, format 3 | clang-16 → iOS 16.0, iPhoneOS16.5.sdk, rootful/rootless/roothide package schemes |
| **Python** | 3.13.14 | OpenSSL 3.0.18, sqlite 3.39.5, 184 stdlib modules |
| **CoreTools** | 2.0 | git 2.39.1, ripgrep 15.2.0, curl 8.22.0, jq 1.8.2, zip/unzip |
| **BuildTools** | - | cmake 3.27.9, ninja 1.11.1 |
| **ReverseTools** | radare2 6.2.4 | rabin2, rasm2, radiff2, rahash2, mt-macho, mt-inject-dylib, mt-rev |

**Runtime source:** [susu123oss/CodexApp-Runtime](https://github.com/susu123oss/CodexApp-Runtime/releases)

All runtimes are pre-compiled for iOS arm64, compatible with TrollStore and jailbroken environments.
Node.js 24 includes full native module support with automatic compilation, signing and loading.

### v1.15 build 14 — what changed

- **Launch crash fixed (really this time).** The entitlement guard existed but
  `ICloudSharedZoneTransport.init()` still built a `CKContainer(identifier:)`
  unconditionally. On an adhoc/TrollStore re-sign that constructor raises an
  ObjC exception Swift cannot catch, so the app died on
  `SyncV2Bootstrap.startIfEnabled → ICloudSharedZoneTransport.init → CloudKit`.
  The container is now `lazy` and every entry point (`start`, `fetchRecentV2`,
  `fetchSessionPortables`, v1 incremental delete) gates on
  `ICloudAvailability.isEntitled` and fails softly. Unentitled builds launch
  with local-only sync instead of trapping.
- **Share-preview dismiss crash fixed.** Closing a PDF preview aborted inside
  PDFKit's tile pool (`-[PDFTileSurface releaseSurface]` →
  `-[PDFPageLayer _releaseTiles]` → `CFRelease` on a dead object). The preview
  no longer uses `PDFView`; pages are rasterized once with `CGPDFDocument` into
  `UIImage`s inside the same zooming `UIScrollView` the long-image preview uses.
  Same 1:1 scale, same pinch/double-tap, no PDFKit tile pool to double-free.

### v1.15 build 12 — what changed

- **Native toolchain is actually found now.** The runtime MT installs keeps
  Theos in a *subdirectory* (`PreparedRuntimes/TheosRuntime/theos/…`) and ships
  **only `usr/bin/zsh`** (no `bash`). The old probe looked one level too shallow
  and required `bash`, so `isAvailable` was always false. It now expands every
  runtime subdirectory, searches `zsh/bash/sh`, includes `<theos>/../usr/bin`
  on `PATH` (make could not find `clang`/`ldid` before), and persists a manual
  root override.
- **Diagnostics + manual repair.** Settings → Agent tools shows a per-item
  ✓/✗ report (Theos / shell / SDK / clang / make / ldid / dpkg-deb) and a text
  field to point at a toolchain root by hand when auto-detection misses.
- **Obfuscation presets.** `off / light / balanced / strong / paranoid` mapped
  to OLLVM `-fla/-bcf/-sub/-split/-sobf`, plus custom CFLAGS/LDFLAGS, `-jN`
  and a package-only mode, all in the visual build workbench.
- **`.deb` runtimes install.** `codex` publishes a Debian package, not a
  tarball. A pure-Swift `ar` reader plus an `libzstd`-backed stream
  decompressor unpack `data.tar.gz` / `data.tar.zst` without dpkg-deb.
- **OpenAI capabilities.** `openai.api` / `credentials` / `chat` / `models` /
  `images` registered into the Capability Registry, plus a bundled (disabled)
  `openai-bridge` example plugin that declares `plugin.openai.assist`.
- **Launch-crash hardening.** iCloud sync now probes `CKContainer` inside an
  Objective-C `@try/@catch`, so an adhoc/TrollStore re-sign that kept the
  entitlement keys but cannot build the container no longer traps at launch.

Details, verification steps and the runtime layout: **[docs/DeveloperRuntime.md](docs/DeveloperRuntime.md)**.

Prebuilt TrollStore package (unsigned/adhoc, requires `platform-application`):

**→ [Releases: v1.15-developer-runtime](https://github.com/JiuJiuyu77/OpenMinis/releases/tag/v1.15-developer-runtime)**

Note: installing runtimes only needs the sandbox-free entitlements. Actually
compiling and signing on device needs TrollStore or a jailbreak; in an App
Store sandbox this screen can download and manage files but the toolchain
cannot execute.

---

## Building from source

Minis ships a Linux sandbox inside the app, so the native dependencies (iSH on
iOS, PRoot on Android, FFmpeg, LAME, rclone) and the Alpine rootfs are **built
from source** rather than committed as binaries.

**→ See [BUILDING.md](BUILDING.md) for the full first-build guide.**

The short version:

```sh
git clone --recurse-submodules https://github.com/OpenMinis/OpenMinis.git
cd OpenMinis

# iOS  — needs Go 1.25+ and Xcode's Metal Toolchain
#        (xcodebuild -downloadComponent MetalToolchain)
#        order matters: FFmpeg links against LAME
./deps/build_lame.sh && ./deps/build_ffmpeg.sh
./deps/build_ish.sh && ./deps/prepare_alpine_rootfs.sh
./deps/build_rclone_ios.sh
open src/ios/Minis.xcodeproj

# Android — needs NDK r28+, Go 1.25+ and gomobile
./deps/build_proot.sh && ./scripts/prepare_android_sandbox.sh
./deps/build_rclone_android.sh
mkdir -p src/android/app/libs && cp deps/build/rclone/rclone.aar src/android/app/libs/
cd src/android && ./gradlew :app:assembleDebug
```

`BUILDING.md` covers the toolchain requirements per platform, the build-time
customization templates, and a troubleshooting section for the failure modes
you are most likely to hit.

---

## Repository layout

```
src/ios/          iOS app (Swift / SwiftUI) + share, widget and file-provider extensions
src/android/      Android app (Kotlin / Compose) + JNI native code
src/shared/       Assets shared by both platforms
deps/             Native dependency build scripts and vendored sources
docs/specs/       Architecture and interface specifications
scripts/          Rootfs preparation and developer tooling
```

---

## Acknowledgements

OpenMinis stands on a great deal of open-source work. Our thanks to the
maintainers of these projects — the full inventory, with versions and license
terms, is in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

**The sandbox** — the heart of the product:

- **[iSH](https://github.com/ish-app/ish)** (GPLv3) — Linux usermode emulation on
  iOS. We run [an ARM64 fork](https://github.com/OpenMinis/ish-arm64).
- **[PRoot](https://github.com/termux/proot)** (GPLv2) — user-space chroot for the
  Android sandbox, via [our fork](https://github.com/OpenMinis/proot);
  **[talloc](https://talloc.samba.org)** (LGPLv3+) underpins it.
- **[Alpine Linux](https://alpinelinux.org)** — the minirootfs the sandbox boots.

**Media & text** — [FFmpeg](https://ffmpeg.org) (LGPL-2.1+),
[LAME](https://lame.sourceforge.io) (LGPL), [cppjieba](https://github.com/yanyiwu/cppjieba) (MIT),
[KaTeX](https://katex.org) (MIT).

**iOS** — [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic),
[SwiftMath](https://github.com/mgriebling/SwiftMath),
[RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary) (all MIT),
[swift-cmark](https://github.com/swiftlang/swift-cmark) (BSD-2-Clause), and the
Apple / Swift Server Workgroup packages (Apache-2.0).

**Android** — [AndroidX & Jetpack Compose](https://developer.android.com/jetpack),
[OkHttp](https://square.github.io/okhttp/), [Coil](https://coil-kt.github.io/coil/),
[kotlinx](https://github.com/Kotlin) serialization & coroutines,
[multiplatform-markdown-renderer](https://github.com/mikepenz/multiplatform-markdown-renderer),
[Reorderable](https://github.com/Calvin-LL/Reorderable), [ACRA](https://github.com/ACRA/acra)
(all Apache-2.0), and [Shizuku](https://github.com/RikkaApps/Shizuku-API) (MIT).

---

## License

OpenMinis is licensed under the **[GNU General Public License v3.0](LICENSE)**.

The app links GPL-licensed components — [iSH](https://github.com/OpenMinis/ish-arm64)
(GPLv3) and [PRoot](https://github.com/OpenMinis/proot) (GPLv2) — so the combined
work is distributed under GPLv3. Bundled third-party licenses are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

---

## Community

- **Telegram**: [Join the group](https://t.me/+2NzhOJuzRyI1YmM1)
- **Issues**: Bug reports, feature requests and discussion via
  [GitHub Issues](https://github.com/OpenMinis/OpenMinis/issues)

This repository is a mirror of a private development tree, so it **does not
accept pull requests** — there is nowhere for them to land. Issues are the way
to shape the product, and [AwesomeMinis](https://github.com/OpenMinis/AwesomeMinis)
and [MinisSkills](https://github.com/OpenMinis/MinisSkills) both do take
contributions. See [CONTRIBUTING.md](CONTRIBUTING.md).
