# Developer Runtime（开发运行时安装器）

本文件描述本分支新增的 **Developer Runtime** 模块：在 Minis 内部下载、校验、安装
并管理 iOS 开发工具链运行时（Theos、OLLVM、ReverseTools 等）。它只做“工具链
管理”，不引入 MT-Agent 的 AI / 聊天 / 账户 / Agent 层。

## 为什么需要它

Minis 原本没有“安装 Theos / OLLVM”的能力，而 iOS 上的编译与签名依赖一套体积很大的
原生工具链（clang、iPhoneOS SDK、ld64、ldid、dpkg-deb）。这些工具不适合打包进 IPA，
因此按运行时清单（runtime manifest）在设备上按需下载安装。

## 组成

| 文件 | 职责 |
|---|---|
| `src/ios/Agent/Runtime/RuntimeManifest.swift` | 解析线上 schema 4 清单（含镜像与本地缓存回退），按 compiler → core → tools 排序 |
| `src/ios/Agent/Runtime/RuntimeTarGzExtractor.swift` | 纯 Foundation + zlib 的流式 `tar.gz` 解包（长文件名、符号链接、多 gzip member、进度、取消） |
| `src/ios/Agent/Runtime/DeveloperRuntimeManager.swift` | 下载（边下边算 SHA-256）、校验、staging 解包、原子替换、移除、取消与清理 |
| `src/ios/Agent/Runtime/DebArchive.swift` | 纯 Swift 的 Debian `ar` 归档读取器（`members` / `extract` / `dataMember`） |
| `src/ios/Agent/Runtime/ZstdDecompressor.swift` | 通过 `dlopen` 使用 `libzstd` 流式解压 `data.tar.zst` |
| `src/ios/Agent/Runtime/OpenAICapabilities.swift` | OpenAI 能力注册（api / credentials / chat / models / images） |
| `src/ios/Views/Settings/DeveloperRuntimeSettingsView.swift` | 设置页：分组列表、安装/更新/移除、进度、错误、占用空间 |
| `src/ios/Views/Settings/SettingsSheet.swift` | 新增 “Developer Runtime” 入口 |

## 行为要点

- **支持两类归档**：`tar.gz`（大多数运行时）与 `.deb`（`codex` 等）。
  `.deb` 会先解析 `ar` 成员表，取出 `data.tar.gz` 或 `data.tar.zst`：
  - `data.tar.gz` → 直接走 gzip + tar 解包；
  - `data.tar.zst` → 走 `libzstd`（设备上通常已有 `/var/jb/usr/lib/libzstd.1.dylib`，
    也会在已安装运行时与 MT 的 TheosRuntime 里找）；
  - 两者都缺（例如 `data.tar.xz`）时明确报错，不会假装成功。
- 若设备上找不到 `libzstd`，`codex` 页面会提示缺少 zstd 解压能力，安装按钮保持可读的失败原因。
- **完整性**：下载过程中流式计算 SHA-256，与清单值不一致即丢弃；`.part` 文件原子落盘。
- **安全边界**：
  - 拒绝路径穿越（`..`、绝对路径）；
  - 符号链接只允许指向安装根目录内部，否则跳过并记录；
  - tar 缺少终止块或 gzip 流被截断时报 `truncated`，不静默接受。
- **解包位置**：解包根即运行时根。Theos 的 `theos/`（含 `makefiles`、`sdks`）与
  `usr/bin` 工具可直接用于 `PATH`；页面会显示实际安装根、SDK 路径与可复制的命令。

## 权限边界

安装后的工具链要真正执行编译，需要 TrollStore / 越狱环境的
`no-sandbox` + `platform-application` 权限（见 `Configs/TrollStore.entitlements`）。
未签名 / App Store 沙盒环境下，本模块只负责下载与文件管理，编译能力不可用。

## 验证方式（本机可复现）

```sh
swiftc -typecheck \
  src/ios/Agent/Runtime/RuntimeTarGzExtractor.swift \
  src/ios/Agent/Runtime/RuntimeManifest.swift \
  src/ios/Agent/Runtime/DeveloperRuntimeManager.swift \
  src/ios/Views/Settings/DeveloperRuntimeSettingsView.swift
```

在设备上、不经过 Xcode 的额外验证：

- 真实清单解码：8 个运行时，7 个可安装（`codex` 为 `.deb`）。
- 真实 Theos 归档（224,552,345 字节，SHA-256 与清单一致）：解包约 40 秒，
  971 MB / 23,858 文件 / 1,198 符号链接，SDK 位于 `theos/sdks/iPhoneOS16.5.sdk`。
- 真实 OLLVM 归档（约 27 MB）：解包 0.7 秒，89 MB / 196 文件。
- 安全用例：路径穿越被拒、符号链接逃逸被阻断、截断与缺终止块均报 `truncated`。

## 构建提示（CI）

`.github/workflows/ios-unsigned-ipa.yml`（手动触发）会在 macOS runner 上按
`BUILDING.md` 顺序构建原生依赖并产出未签名 IPA。注意 iSH 的 arm64 VDSO 目标硬编码
`-fuse-ld=lld`，Homebrew 的 `llvm` keg 不含 `ld.lld`，因此必须额外安装 `lld`。

## 执行器（Executor）与能力注册表

这三个开关位于 `设置 → 执行器（Executor）`：

| 开关 | 存储键 | 行为 |
|---|---|---|
| 默认执行器 | `toolExecutor.mode` | `auto`（默认，留在 iSH）/ `sandbox` / `native` |
| 沙箱模式 | `toolExecutor.sandboxMode` | 强制只走 iSH，覆盖上面的选择 |
| 优先使用自定义 Runtime | `toolExecutor.preferCustomRuntime` | 让 `auto` 改用 Developer Runtime 装的工具链；同时让 `NativeToolchain` 优先探测 `Application Support/DeveloperRuntime/installed` |

`auto` 刻意**不会**因为“存在工具链”就改走原生：MT-Agent 的安装里本来就有一份工具链，
那样会让所有命令静默离开 iSH 沙箱。原生执行必须显式开启。

相关文件：

| 文件 | 职责 |
|---|---|
| `src/ios/Agent/NativeBuild/ToolExecutorPreference.swift` | 三个开关 + `executionDecision` 快照 |
| `src/ios/Views/Settings/ToolExecutorSettingsView.swift` | 设置页与只读能力列表 |
| `src/ios/Agent/Chat/AIChatViewModel+ISHCommand.swift` | `shell_execute` 按决策分流；`/var/minis/…` 始终留在沙箱 |

### Capability Registry

`CapabilityRegistry.shared` 是“这个构建现在能不能做 X”的唯一查询入口：

```swift
CapabilityRegistry.shared.isAvailable(CapabilityID.iosToolchain)
CapabilityRegistry.shared.report()      // 全部能力 + 不可用原因
```

内建能力（`BuiltinCapabilities`，provider `builtin`）只读取既有管理器的状态，
不缓存第二份真相：

| id | 判定来源 |
|---|---|
| `shell.sandbox` | `ISHKernel.shared.isBooted` |
| `exec.native` | `ToolExecutorPreference` + `NativeToolchain.isAvailable` |
| `ios.toolchain` | `NativeToolchain.theosRoot`，或 `DeveloperRuntimeManager.installedCapabilities` |
| `ios.ollvm` | 同上（`ollvm` / `ios.ollvm`） |
| `fs.workspace` | Application Support 可写 |
| `sync.icloud` | `ICloudAvailability.isEntitled` |
| `plugin.host` | 恒为可用（插件各自的能力单独注册） |

### 插件能力（Plugin Capabilities）

插件在 `MinisConfig/plugins/<id>/manifest.json` 里声明能力：

```json
{
  "id": "acme.toolbox",
  "name": "Acme Toolbox",
  "enabled": true,
  "capabilities": [
    { "id": "plugin.acme.lint", "display_name": "Acme Linter",
      "kind": "plugin", "requires": ["fs.workspace"],
      "summary": "Static analysis for Swift sources." }
  ]
}
```

- `PluginManifestStore` 扫描目录，把声明同步进 `PluginCapabilityBridge`；
- 插件被禁用或目录消失时自动 `unregister`，能力随之从列表消失；
- 桥只回答“声明的能力现在算不算数”，不执行插件代码。

## iCloud 未授权时的降级（崩溃 2 修复）

adhoc / TrollStore 重签会丢掉 `com.apple.developer.icloud-*` 权限，此时
`CKContainer(identifier:)` 会抛 Objective-C 异常（`EXC_BREAKPOINT`），Swift 的
`do/catch` 拦不住。`src/ios/Agent/Sync/ICloudAvailability.swift` 用 `dlsym` 取
`SecTaskCreateFromSelf` / `SecTaskCopyValueForEntitlement` 判断签名是否带权限。

所有会构造 `CKContainer` 的入口都先检查它：

- `SyncV2Bootstrap.startIfEnabled()`、`CloudSyncEngine.start()` → 直接降级为本地模式
- `CloudSyncEngine.deleteAllCloudData()` / `discoverDeviceZones()` → 抛错 / 直接返回
- `MigrationEngine.countOwnZone` / `purgeZone` / `deleteOwnZone` → 抛
  `MigrationError.iCloudUnavailable`；`listAllZones()` 返回空列表
- `DebugJSONRPC` 的 `debug.sync.*` → 返回 `{"ok": false}`

结果是：没有 iCloud 权限的构建里同步静默关闭，App 正常启动，不再闪退。

## OpenAI 能力与插件

`OpenAICapabilities.swift` 把 OpenAI provider 的可用性表达成一组能力，注册进
`CapabilityRegistry`（与 `BuiltinCapabilities` 并列、各自幂等）：

| 能力 id | 判定 |
|---|---|
| `openai.api` | 存在已启用的 OpenAI provider 实例 |
| `openai.credentials` | 该实例有 API Key 或 OAuth token（或允许空 Key） |
| `openai.chat` | 依赖 `credentials` |
| `openai.models` | 依赖 `api` |
| `openai.images` | 依赖 `chat`，仅对声明了图像端点的实例可用 |

插件侧：`PluginManifestStore.installBundledExamplesIfNeeded()` 首次启动会写入
`MinisConfig/plugins/openai-bridge/manifest.json`（**默认 disabled**），它声明
`plugin.openai.assist` 并 `requires: ["openai.chat"]`，作为“插件 + 能力”组合的示例。
设置 › Agent 工具 › 执行器 / 能力 页面可以查看能力状态、启用插件与重扫。

## 下载超时与断点续传（build 13）

`codex` 的 `.deb`（约 100MB）经重定向到 CDN，`URLSession.shared` 的 60 秒
请求超时会让每次尝试都在 TLS/重定向阶段就失败，界面表现为「Codex 下载超时，
无法安装」。现在：

- 下载使用**独立 session**：`timeoutIntervalForRequest = 120`（块间空闲）、
  `timeoutIntervalForResource = 2 小时`（整包）。
- 每个候选地址最多重试 3 次，失败时保留 `.part` 并用 `Range: bytes=<n>-`
  **断点续传**，哈希从已写好的前缀继续累计。
- 服务器忽略 Range（回 200 全量）时丢弃前缀重下，避免把整包追加到前半段后面。
- 传输提前结束（连接被关闭）按可重试错误处理，而不是报成 SHA 校验失败。
- 切换镜像前会删掉旧镜像留下的 `.part`，因为不同镜像的字节不保证可拼接。

## OLLVM 识别（build 13）

「已安装 OLLVM 却显示未安装」的根因是三处判断各写了一套字符串，而 manifest
实际发布的是 `compiler.ollvm.frontend` / `compiler.ollvm.obfuscation` /
`compiler.ollvm.ios-artifact`。现在统一到 `RuntimeCapabilityNames`：

- `ollvmInstalled` 对 `compiler.ollvm.frontend`、`compiler.ollvm.obfuscation`、
  `ios.ollvm`、`ollvm` **任意一个**命中即为真；
- 编译工作台、`native_build` 工具、能力注册表都读这一个判断；
- 运行时诊断页额外列出每个别名在本机的实际状态，并探测「OLLVM 版 clang」
  （扫描运行时 `usr/bin` 下的 clang，检查二进制里是否含 `-fla` pass 名）。

## 运行时诊断页

`设置 → Agent Runtime → 运行时诊断` 汇总四组信息，全部本机探测、零网络：

1. 工具链逐项（Manual path / Theos / Shell / SDK / clang / make / ldid /
   dpkg-deb / Runtime bin / Tool shims）；
2. OLLVM：能力别名逐项 + 找到的混淆编译器；
3. 运行时清单：每个运行时的已装/过旧/未装状态；
4. 执行器：有效执行器、是否「优先自定义 Runtime」、是否强制沙箱。

## 清单 install 块自检（本分支新增）

清单里 `install` 块此前被完全忽略：装完即「成功」，于是缺 `devkit/node/include`、
缺 `Frameworks/NodeMobile.framework` 或 `bin/` 里只有半个工具的树，也会被记成已安装。
现在按清单契约补齐三件事。

| 文件 | 职责 |
|---|---|
| `src/ios/Agent/Runtime/RuntimeInstallSpec.swift` | 解码 `install`（`required_paths` / `path_entries` / `persistent_path_entries` / `environment` / `probe` / `sign_paths`），并把清单环境翻译成子进程环境 |
| `src/ios/Agent/Runtime/RuntimeInstallVerifier.swift` | 解包后自检：路径闸门 + `probe` 真实执行（`posix_spawn`，不用 `Process`——iOS 上没有） |
| `src/ios/Agent/Runtime/DeveloperRuntimeManager.swift` | 在 staging 里先验再提交；记录自检结论；环境导出改走 overlay；依赖计算补上能力级 `requires` |

### 三种自检结论

| 结论 | 触发条件 | 安装结果 |
|---|---|---|
| `passed` | 路径齐 + probe 退出码 0 + 输出含 `contains` | 提交 |
| `skipped` | 路径齐，但当前环境不能执行设备原生二进制（App 沙盒 / 侧载） | 提交，UI 显示「未自检 + 原因」 |
| `failed` | 路径缺项 / probe 起不来 / 输出不匹配 / 超时 | **不提交**，暂存目录丢弃，上一份可用安装保留 |

失败不会覆盖已有运行时：换版本失败时，用户手上的 Theos 仍然是能编译的那一份。
probe 输出会被截断到 4KB 并写进日志与设置页，便于区分「包坏了」和「环境不允许执行」。

### 环境导出（清单优先于目录猜测）

`DeveloperRuntimeManager.environment(for:)` 不再猜 `usr/bin` / `bin`，而是按清单：

- `install.path_entries` → `PATH` 前缀（缺项回退到 `usr/bin`、`bin`）；
- `install.environment` → 原样导出，`${RUNTIME_ROOT}` 展开为安装根；
- 额外导出 `CA_RUNTIME_ID` / `CA_RUNTIME_VERSION` / `CA_RUNTIME_HANDLER` /
  `CA_RUNTIME_ROOT` / `CA_TOOL_<ID>_RUNTIME_ROOT`（键名大写下划线，与运行时端一致）；
- `handler: theos` 时按树结构派生 `CA_THEOS_SDKROOT` / `CA_THEOS_CLANG` /
  `CA_THEOS_CLANGXX` / `CA_THEOS_MAKE` / `CA_THEOS_BASH`，同时保留旧的
  `THEOS` / `THEOS_SDKROOT` 键。

这几个 `CA_*` 不是新发明：Node 运行时的 `lib/codex/native-support.js` 用
`CA_TOOL_NODE_RUNTIME_ROOT` 定位自身、用 `$SHELL || $CA_THEOS_BASH` 选 shell，
`ios-bootstrap.js` 用 `CA_THEOS_SDKROOT` + `CA_THEOS_CLANG` 决定是否注入
`SDKROOT` / `CC` / `CFLAGS` / `LDFLAGS` / `GYP_DEFINES`。导出这些变量，装的 Node
运行时才真的能 `npm install` 编原生扩展，而不是「装着但用不起来」。

### 依赖解析包含能力级 `requires`

`missingRequirements(for:)` 现在同时看两处：

- 运行时级 `requires`（裸 id 或 `{id, provides, reason}` 对象，两种都解码）；
- 能力级 `capabilities.<id>.requires`，例如 `node.native-addon` 依赖 theos 提供的
  `ios.toolchain`、`build.cmake-ios` 同样依赖 `ios.toolchain`。

只装 Node 不装 Theos 时，能力页会直接说缺什么，而不是等到编译阶段才失败。

### CI

`.github/workflows/runtime-contract.yml`：

1. **manifest** —— 每天 + 每次改动跑 `scripts/check_runtime_manifest.py`，校验线上清单
   仍是 schema 4、handler 都在安装器实现范围内（`portable-v1` / `codex` / `python` /
   `theos` / `reverse_tools`）、归档格式可解（`.tar.gz` / `.tgz` / `.deb`）、
   `install` 块不会放行坏包（绝对路径、probe 不在 `required_paths` 内、
   `sign_paths` 越界、环境值缺 `${RUNTIME_ROOT}`）、摘要为 64 位小写 hex；
2. **swift-syntax** —— Ubuntu + Swift 6，`swiftc -parse` 解析 Runtime 目录与设置页
   （只校验语法，不需要 iOS SDK），并断言自检与 overlay 仍接在管理器上。

## 三层执行链：shell / 工具链 / 签名（本分支补齐签名层）

要在真机上真正编译并运行原生二进制，三层缺一不可。前两层本分支之前就已经存在，
这一轮补的是第三层。

| 层 | 组成 | 状态 | 代码位置 |
|---|---|---|---|
| 1. 执行层 | `Helpers/bash.real`（真 bash，Darwin syscall + `posix_spawn`），不是 iSH 里的 Linux busybox | 已有（找不到时依次回退 `/var/jb/usr/bin/bash`、`/bin/bash`、`/bin/sh`，并在 `Helpers/`、`TheosCompat/`、`TheosCoreCompat/` 里补 coreutils 别名） | `NativeBuild/NativeToolchain.swift`、`NativeBuild/NativeCommandRunner.swift` |
| 2. 工具层 | Theos 运行时：`clang-16`、`ld64`、`ar`、`strip`、`ldid`、`dpkg-deb`、`iPhoneOS16.5.sdk`、makefiles/headers/lib | 已有（真机 arm64 编译，不交叉模拟） | `Runtime/DeveloperRuntimeManager.swift`、`NativeBuild/NativeToolchain.swift` |
| 3. 签名层 | `ldid -S<entitlements>` 写权限 → `codex-sign` 补 App Store 形态 CodeDirectory（TeamID + cdhashes） | **本分支新增** | `Runtime/RuntimeSigning.swift` |

### 为什么必须两步

只做 `ldid` 是「签名残缺」：`posix_spawn` 可能过得去，但一执行就被杀，表现为
`Bad executable` 或 `Killed: 9` —— AMFI 不认这个签名结构。`codex-sign` 在 adhoc
签名之上重写签名 superblob：Thin/FAT 归一到 arm64、补 cdhashes、设置 TeamID，并走
TrollStore 的 CoreTrust 绕过路径。

### 权限来源（不硬编码一份 plist）

`RuntimeSigner.entitlementsPlist()` 从**本进程自身签名**里挑出可传播的这 8 条：

`platform-application`、`com.apple.private.security.no-sandbox`、
`com.apple.private.security.no-container`、
`com.apple.private.security.storage.AppBundles`、
`com.apple.private.security.storage.AppDataContainers`、
`task_for_pid-allow`、`get-task-allow`、`proc_info-allow`

`Configs/TrollStore.entitlements` 里这些已经都在（另外还有
`com.apple.private.skip-library-validation`，用于让 dyld 接受 CDHash 与主程序不同的
运行时二进制）。App 本身不是以这些权限签名时（App Store / 普通侧载），签出来的东西
也没有意义——signer 直接返回 `skipped`，不会假装成功。

### 装完自动签名

`DeveloperRuntimeManager` 在自检通过后备好 `install.sign_paths`（带权限）与
`install.sign_paths_without_entitlements`（adhoc-only），逐个：

1. `ldid -S<tmp>/entitlements.plist <file>`
2. `codex-sign [--entitlements plist] <file>`

结论落在安装记录里（`RuntimeSignReport`），设置页显示 `Signed (ldid + codex-sign)`、
`Ad-hoc signed only`、`Signing skipped`、`Signing failed` 四种之一。签名失败会让安装
失败并保留上一份可用的运行时——一个「装了但执行即崩」的工具链比没有更糟。

### 把 bash.real / codex-sign 放进包

`Helpers/` 目前不在 Xcode 工程里，需要一次构建配置（不是代码改动）：

1. 把 `bash.real`、`codex-sign`（可选 `ca-filetool`、`ldid`）放到 `Configs/Helpers/`；
2. 在 Minis target 里加一个 Run Script 构建阶段（放在签名阶段之前）：
   `"${SRCROOT}/scripts/stage_app_helpers.sh"`；
3. 脚本会把文件复制到 `<App>.app/Helpers/`、补 `bash`/`sh`/coreutils 软链，并用当前
   签名身份对副本做一次 adhoc 签名（`Configs/Helpers/` 为空时整体 no-op，不影响普通构建）。

`codex-sign` 没进包也能跑：signer 会退化成 `Ad-hoc signed only` 并在记录里写明原因；
也可以把 `codex-sign` 放到 `Application Support/DeveloperRuntime/Helpers/codex-sign`，
不重新打包即生效。
