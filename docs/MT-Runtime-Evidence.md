# MT-Agent 1.0.9 Lite 通用运行时静态证据

Reference archive SHA-256: `6aa57a515561cd3fa764571c80a53c4046c171d04ce848362440c8fb8c04f7b3`

分析对象：`/var/minis/attachments/uploads/MT-Agent-v1.0.9-Lite_1_1.tipa`；独立解包目录 `/var/minis/workspace/mt-reference`。只做静态分析，未运行包内任何 Mach-O，未读任何 gittoken 文件，未改 OpenMinis 源码。本文地址均为附件二进制首选虚拟地址（无 ASLR slide）；主程序地址以 `0x100...` 为基址。置信度：**高**=直接文件/常量/调用参数；**中**=可见方法和调用链但未完全恢复分支；**未知**=不能据静态证据保证。

## 立即可用的确定发现

### Root persona 精确 ABI（高）

`CAAgentRuntimeManager personaAPIsAvailable` 位于 `0x1000250f4`。其 `0x100025120` 调 once 初始化，`0x100025124–0x100025130` **仅检查 set_persona_np 指针非空**，不要求 uid/gid 两个指针都存在。

once block 位于 `0x10003c504`，对 3 个字符串做 XOR 解码后，使用 `dlsym((void *)-2, name)`（RTLD_DEFAULT）动态解析：

| 函数 | dlsym 地址 | 存放指针 |
|---|---|---|
| `posix_spawnattr_set_persona_np` | `0x10003c590` | `0x1008a6f60` |
| `posix_spawnattr_set_persona_uid_np` | `0x10003c614` | `0x1008a6f68` |
| `posix_spawnattr_set_persona_gid_np` | `0x10003c698` | `0x1008a6f70` |

解码脚本 `mt-reference/decode_persona.py`，明文/密文地址证据 `persona-decoded.json`，完整初始化汇编 `disassembly/persona-init.asm`。并非仅根据常见 TrollStore 实现猜测。

`launchCodexExecutable:arguments:currentDirectory:environment:outputHandler:errorHandler:terminationHandler:error:` 尽管命名带 Codex，通用执行器也调用它。`0x100026504–0x10002651c`：

```c
posix_spawnattr_init(&attr);
set_persona_np(&attr, 99 /*0x63*/, 1 /*override flag*/);
// 后两个函数存在时各自调用
set_persona_uid_np(&attr, 0);
set_persona_gid_np(&attr, 0);
posix_spawnattr_setpgroup(&attr, 0);
posix_spawnattr_getflags(&attr, &flags);
posix_spawnattr_setflags(&attr, flags | 2 /*POSIX_SPAWN_SETPGROUP*/);
posix_spawn(&pid, executable, &file_actions, &attr, argv, envp);
```

uid 0 见 `0x10002656c–0x100026574`；gid 0 见 `0x10002659c–0x1000265a4`；pgroup/flags 见 `0x1000265a8–0x1000265d0`；spawn 见 `0x100026600`。主启动器还有普通权限 fallback（`0x100026634–0x100026694`）。**但特权安装层不容许静默降级**：`CARuntimeCommandExecutor` 的 requireRootPrivilege 路径出现“当前环境不支持 root persona，无法执行特权 Runtime 操作”和“root persona 启动失败，已拒绝以普通权限执行安装”（`0x10021d704/0x10021d70c`），可复刻时应区分普通命令与安装/签名的 strict-root 要求。

### Helpers 不是一组独立小工具（高）

ZIP external_attr 记录：`Helpers/sh`、`bash`、`bash-codex`、`theos-helper` 以及大多数 core applet 为 **symlink**，链接内容是 `ca-filetool`。`Helpers/bash.real`、`codex-sign`、`ca-filetool` 才是真实 Mach-O。本次为便于取证把链接内容保存为普通文件，不能把解包目录中的这几个 11 字节文件当可执行脚本；完整 mode 在 `inventory.json`。

**因此“sh 不可指向 ca-filetool”不符合 MT 附件事实**：MT 的 sh 就指向它，但它不是 shell 解释器本体，而是 argv[0] 分发/转交同目录 bash.real 的 trampoline。缺少 bash.real 时，该布局不能正常工作；仅复制 ca-filetool 不等于提供 bash。

### 授权与分发风险（高/中，后续补充具体函数分支）

`ca-filetool` 明文含 `CA_BUILD_AUTHORIZED`、`theos-helper: artifact build authorization unavailable`（字符串 VA `0x100019ffd`, `0x10001a013`）；主函数 `0x1000077d4` 读授权变量。这个 helper 不能当作与 MT 无关的透明 coreutils 分发包。

主程序中还明确存在“Artifact build authorization is disabled by CodexApp remote policy”等策略字符串；这说明 **MT 的构建授权和“已安装工具链”是两个不同状态**。独立 Minis 应实现自己用户授权/能力策略，不要声称移植 helper 就复现 MT 授权服务。本文仅分析，不提供绕过第三方授权逻辑。

### 许可证与可复现性（高）

`ThirdPartyNotices/Runtime-Components.txt` 宣称 bash、signer 的对应源码与 build script 在 `ThirdPartySources/`；**Lite ZIP 中没有该目录**。其声明 Bash 5.3、GPL-3.0-or-later；fastPathSign 独立 GPL-3.0 可执行文件，来源 TrollStore/ChOma/OpenSSL。不能仅复制 notices 就宣称已满足对应源码提供义务；建议用户本地可追溯导入，或从公开源码重新构建并保存完整源/补丁/版本/构建说明。`codex-sign` 是签名辅助工具，与 Codex agent/app-server 业务无关。

## 取证产物

`mt-reference/inventory.json`（附件/逐文件 SHA256 与 ZIP mode）、`Info.plist.json`、`entitlements.plist.json`；`analysis-CodexApp/{layout.json,strings.tsv,symbols.tsv,function-starts.txt}`；`analysis-ca-filetool/`、`analysis-codex-sign/`；`objc-methods.tsv` / `.json`；`runtime-methods.txt`；`environment-keys.tsv`；`address-labels.json`；`disassembly/{managed,catalog,executor,launcher,persona-init,security,theos,archive,paths,ollvm,CAPythonEnvironment,ca-filetool,codex-sign}.asm`。注释为自写 Mach-O/ObjC metadata + Capstone 静态解码，不是反编译源代码；控制流混淆处仍需按实际跳转校验。

## Shell 启动契约与 helper 的精确授权范围

### 非登录 shell：不要把 `-lc` 的存在误判为默认启动参数（高）

`CAShellEnvironment codexArgumentsForEnvironment:`（`0x1002450b8`）直接向运行配置注入 **`allow_login_shell=false`** 和 **`features.shell_snapshot=false`**（`0x10024511c/0x100245124`）；另有 `shell_environment_policy.set.<key>=<value>` 显式保留 PATH/SHELL/CONFIG_SHELL/CA_* 等（`0x10024580c`, `0x100245c24`）。这里仅取 shell 环境契约，不复刻 agent/app-server。

字符串 `-lc` 确实存在（VA `0x100750dea`，CFString `0x1007b3808`），但已恢复交叉引用主要来自命令分类器 `commandRequiresTheosRuntime:`（`0x1000e1d80`）和兼容性探针（`0x1002210dc`, `0x100222658`），**不是默认 shell spawn 的证据**。`shell-xrefs.json` 保存所有候选机器码引用，可能有近邻 ADRP 假阳性；必须连同汇编判断。

确定的 native helper 路径：`bash|sh|bash-codex` basename → 同目录 `bash.real`，构造 `argv_new[0]=bash.real 的文件系统路径`，原样复制原始 `argv[1:]`（`0x100007444–0x100007488`），所以 trampoline **不会自行添加 `-l`/`-lc`**；也不会保留 `argv[0]=sh` 触发 GNU Bash 的 sh-mode。它 `setenv(LC_ALL,"C",1)`、`setenv(LANG,"C",1)`、`unsetenv(LANGUAGE)`（`0x100007408–0x100007440`），不在这段改 PATH；`posix_spawn` 使用当前 `environ`，继承 stdin/out/err，设置与当前父进程相同的 pgroup，然后 waitpid，把 exit status 或 `128+signal` 返回（`0x1000074b0–0x1000075fc`）。**shell 启动应采用非登录 `-c <command>`，避免登录脚本重置注入 PATH；这是与 MT 的显式禁用 login 配置一致的可复刻建议，不声称已观察到所有上层 shell argv。**

### ca-filetool 是否真的依赖 MT 授权？精确答案（高）

不是所有 applet 都依赖。`Helpers/ca-filetool` `_main=0x100006d84` 中：

1. basename 为 `theos-helper` **且 argv[1] 是 `format-control`** 时，在 `0x100006ddc–0x100006dfc` **直接进入专用 C 快速路径 `0x100006f6c`**，不经过后续授权检查。
2. basename 为 `bash`、`sh`、`bash-codex`，在 `0x100006e38–0x100006e70` 进入上述 trampoline，同样不经过 `CAFileToolMain` 的授权分支。
3. 其余进入 `_CAFileToolMain=0x100007730`。这里只在 **basename 为 `theos-helper`** 时（CFString `0x10001c450`; 比较 `0x1000077cc`），读取 `CA_BUILD_AUTHORIZED`；缺失或不等于 `"1"` 则输出 `theos-helper: artifact build authorization unavailable`，**返回 77 (`0x4d`)**，见 `0x1000077d4–0x100007818`。
4. 因此 `upper` / `schema-key` / `sort-versions` / `hash8` / `control-field` / `installed-size-kb` / `package-build-number` / `verify-deb` / `assemble-deb` / `build-deb-forkless` / `fakeroot` 等通过 `theos-helper` 使用的常规分派依赖该环境授权；上面的 `format-control` 快速路径例外。普通 `ls/cp/mv/tar/...` applet **没有这里的授权检查**。
5. helper 自身在这个分支只是读环境值，未发现联网或对 MT bundle id 的验证证据。**MT app 主程序另有远程策略控制**，从 `buildArtifactsAllowed` 注入 `CA_BUILD_AUTHORIZED=0/1`（`CAShellEnvironment` 中 `0x100242b48–0x100242b68`；主程序内置 `_CAFileToolMain` 也有对应策略）。不要把“helper 本地 env gate”描述为“整个 helper 必须访问 MT 授权服务器”。也不要声称复制可绕开 host 端策略；独立实现应使用 Minis 自己的授权来源。

### TheosCompat / TheosCoreCompat（高）

ZIP 中 `TheosCompat/{cp,mv,tar}` 是链接到 `../ca-filetool`，`TheosCoreCompat/{touch,mkdir,rm}` 同理；它们是隔离的兼容 applet PATH 层，不是 SDK/toolchain 本体。`CAShellEnvironment environmentByAddingShellTo:bundleHelpers:activeHelpers:` 在 `0x100243c90/0x100243dfc` 处理这两个目录；`CATheosEnvironment environmentByAugmentingEnvironment:` 在 `0x10026d420/0x10026d5e8` 再处理（`disassembly/shellenv.asm`, `theos-env.asm`）。`CA_THEOS_TAR_ABI` 明确为 `compat` 或 `native`（`0x10026d05c–0x10026d074`）；包模式为 `forkless` 或 `native`（`0x10026cc34–0x10026cc4c`）。不能把这个执行后端模式误当 rootful/rootless/roothide **输出包格式**。

普通 applet 是有限子集，不等于全量 BSD/GNU 工具：`ca-filetool` 使用说明字符串 VA `0x10001acf5` 列出 ls/cat/nl/head/tail/wc/find/sed/grep/sort/cp/mv/rm/mkdir/touch/uniq/tee/basename/dirname/readlink/realpath/du/ln/chmod/which/stat/date/xxd/od 的支持 flags；例如其 sed 并非通用 sed。复刻应基于能力探针，不要只根据文件名宣称可用。

## 清单、安装、缓存与恢复契约

### 清单来源和解析（高）

附件 `Info.plist`：版本 1.0.9/build 26，bundle id `wiki.qaq.codexapp`，`CARuntimeManifestURL=https://raw.githubusercontent.com/susu123oss/CodexApp-Runtime/main/Runtime/runtime-manifest.json`。**不是技能文档中的 JiuJiuyu77 上游源**，复刻默认源必须由用户/产品明确决定，不宜悄悄换成另一个同名仓库。

`CARuntimeCatalog manifestURLString=0x100217f7c` 从 Info 取该键；`entriesFromData:error:=0x100218608` 解析顶层 `runtimes`；读取字段：`display_name/summary/handler/group/version/revision/archive_url/archive_sha256/download_size/unpacked_size/order/optional/install/provides/requires/recommends/conflicts/capabilities/ui`。读取具体地址见 `disassembly/catalog.asm`。runtime id 用 `[a-z0-9._-]` 白名单（`0x100218a38`）。fallback handler 对 theos/python/reverse_tools 有专用逻辑，portable handler 是 `portable-v1`（`0x100219a9c`）。**没有从附件证明 app 强制 schema_version==4**；不要把外部技能 schema4 校验器当成 MT 二进制行为。

远端清单实时请求因当前 iSH TLS trust chain 验证失败（curl 60）未成功；未绕过 TLS。本文没有把今天远端资产内容冒充附件内版本。Lite **没有打包任何 Node/Python/Theos/OLLVM/Core/Build/Reverse runtime 树或压缩包**；只有 host + Helpers，具体 runtime 版本/完整 provides 不能从 Lite 文件清单独立确定。

### portable-v1 通用安装（高，激活异常边界中）

对应类 `CAManagedRuntimeEnvironment`；不是为 node/core/build 各写一个固定下载器。

1. 校验 handler 为 portable-v1，否则提示“此 Runtime 需要专用安装器”（`0x1001a4df8`）；并发忙碌状态阻止重复操作。
2. 以 id/version 关联下载缓存，缓存 basename `runtime.tar.gz`，路径组件 `CodexApp/RuntimeDownloads/Managed`（`cacheDirectoryForEntry:=0x1001a0764`；细节见 managed.asm）。已缓存归档先算 SHA256 与远端 lowercase archiveSHA256 比较（`0x1001a524c–0x1001a52ac`）；不匹配重新下载，下载后再验证（`0x1001a5408–0x1001a54cc`）。**自动本地恢复与手动在线安装不同：恢复 checksum 不符不做网络 fallback**，日志 `0x1001a9fbc` 明写 `(no network fallback)`。
3. 通用下载 URL 要 https 且 host 非空（`0x1001a09d0–0x1001a0a68`）。候选首先原 URL；仅 host=github.com 时追加 `https://gh-proxy.org/` + 原 URL、`https://ghproxy.net/` + 原 URL（`0x1001a0af0–0x1001a0c50`）。**portable 通用下载器这里是内置代理列表**；Python/Theos/Reverse 另有 `downloadProxyPrefixes`/`download_proxy_prefixes` 解析，不应默认它们完全相同。
4. 下载和 hash 后，`CARuntimeCoordinator performExclusiveOperationForRuntimeID:stage:block:` 串行化“解压/签名/激活”（`0x1001a55d4`）；staging 目录组件 `ManagedRuntime.installing/<id>`，tar.gz 解到 staging（`0x1001a59dc`, `0x1001a5ba0`）。
5. `validateEntry:staging:signPaths:signPathsWithoutEntitlements:error:=0x1001a1cec` 要求非空 `install.required_paths`，逐一验证安全相对路径及存在性；读取两类 sign paths，探针及 environment。可见错误分别为 required/sign_paths/无 entitlement sign targets/probe 配置不合法，不能省略。
6. `safeID:=0x10019ddac` 使用小写 id 字符白名单；`safeRelativePath:=0x10019ded8` 拒绝以 `/` 开始、含 `..`、含 `\\`（具体 contains 判断见 managed.asm）。environment 不是任意字典：`isAllowedPortableEnvironmentKey:=0x10019da00` 要求 **`CA_TOOL_` 前缀 + 大写字母/数字/下划线**，否则报“Runtime environment 仅允许 CA_TOOL_*”（`0x1001a30f8`）。这是比泛化 adapter 更窄的重要契约。
7. 校验 `persistent_path_entries`、`probe.executable/arguments/contains`；探针 executable 要安全且在 staging 中存在（`0x1001a3700/0x1001a3804`），arguments 和 contains 有类型校验；probe payload JSON 过长也拒绝（`0x1001a4c78`）。
8. 先签名，再生成 probe payload（`0x1001a5d74/0x1001a5dd8`），然后启动 **host 自身的隐藏 native 子命令** `-agent-install-managed-runtime` 完成 activation/self-check（`0x1001a5fdc`, `0x1001a6088`），不是仅 move 然后相信文件存在。目标 root 明确为 **`<appBundleRoot>/ManagedRuntimes/<id>`**（`rootForID:=0x10019dfdc`）；revision 标记 `<root>/.codex-runtime-revision`（`0x10019e194`）。
9. 激活后绑定完整性（`0x1001a6588` 失败会报“Runtime 完整性记录失败，请重新安装”），写 installed version/desired 状态，发 `CAManagedRuntimeEnvironmentDidChangeNotification`。已安装判断还会查 required_paths + revision + security binding，不能只看目录。
10. hidden remove 协议 `-agent-remove-managed-runtime`（`0x1001a6ca0`）；恢复从缓存归档及 desired 状态重建应用替换后消失的 bundle 内 runtime。root 激活中的 `.backup`、revision、probe 字段处理在 `disassembly/activation-main.asm` 的 `0x10002fd00–0x100034a48` 区域；**存在备份/回滚线索，但不宣称全部错误分支的原子事务已经完整还原**。

### 解压安全（高）

`CAArchiveExtractor extractTarGzip...=0x100054c64` 使用 gzip/TAR 静态实现（imports `_gzopen/_gzread/_gzclose`），不是系统 `tar -x` 黑箱。明确检查：不安全路径（`0x10005641c`）、symlink/hardlink 越界（`0x100055b1c`）、TAR 条目/对齐截断、提前结束、展开大小错误（`0x1000562b0/0x100056504`）。安全可复刻：验证每个 normalized entry 位于 staging；链接目标也检查 containment；拒绝解压炸弹/长度溢出；保留执行位和合法内部链接。**是否 flatten 单层顶目录没有足够证据**，不能直接沿用技能 adapter 的 flatten 规则当原行为。

## 签名与可信执行

### 签名工具真正 CLI（高）

`Helpers/codex-sign` `_main=0x100009c64`：

```text
codex-sign [--adhoc-only] [--entitlements plist] file [file ...]
```

参数顺序重要：先只在 argv[1] 识别 `--adhoc-only`（`0x100009ca4–0x100009cc4`），再在当前位置识别 `--entitlements`（`0x100009cd0–0x100009ce0`）；不是通用 getopt 任意排序。

默认模式对每文件先 `_codesign_sign_adhoc(..., entitlements)` 再 `_CAExtractPreferredSlice`、`_apply_coretrust_bypass`、copy 回原位置，恢复 uid/gid/mode（`0x100009d20–0x100009d84`）。`--adhoc-only` 分支不执行该 CoreTrust bypass；对嵌套 FAT 有 preferred slice thinning（日志 `0x100009dcc`），再 ad-hoc sign（`0x100009e04`）。不要把它简化成 `ldid -S` 同义词。

通用 installer `signPaths:withEntitlements:staging:error:` 用 bundle `Helpers/codex-sign` 和 bundle `entitlements.plist`。区分 `install.sign_paths`（带 entitlement）与 `install.sign_paths_without_entitlements`（不附加 host entitlement）；以 **每批最多 16 文件** 调签名器（`0x1001a42c8–0x1001a42dc`，循环 `0x1001a437c`）。root mode=roothide **且** install channel=deb 时选 `--adhoc-only`，日志标 `adhoc-only+jbclient`，否则 `coretrust`：roothide 测试 `0x1001a3fd4`，deb 测试 `0x1001a4040`；已按实际跳表验证 roothide=false 会到 `0x1001a43b0` 设置模式 false。**jbclient 后续 trust 的完整调用 ABI 未还原，不可仅凭日志声称已实现**。

### Entitlements 实证与移植注意（高）

`binary-signatures.json` 直接解析 LC_CODE_SIGNATURE SuperBlob，发现 **CodexApp 与三个真实 helper 都嵌入了 host 级 entitlement**，不仅旁边有 plist。包含 platform-application、no-sandbox、no-container、persona-mgmt、AppBundles/AppDataContainers storage、get-task-allow/task_for_pid/proc_info、extended-virtual-addressing、group.wiki.qaq.codexapp。**这些是 MT 的签名内容，不是给 Minis 的权限建议**；直接搬二进制会携带 MT app-group 身份。独立导入/构建应基于自身 entitlement 最小集和目标分发环境重新签名；不能保证沙盒 App Store 环境能 spawn/persona。

### 完整性绑定并非全目录哈希（高）

`CARuntimeSecurity` 存 `RuntimeSecurity/integrity-v1.json`，format=`runtime-integrity-v1`，记录 revision/root/components。`fileIdentityAtPath:relative:=0x10023bdb0` 拼 `type/mode/size`、link target；对选定元数据文件调用 `sha256ForSmallMetadataFile:=0x10023babc`。该方法在 `0x10023bb88` 对大小 **8 MiB (`0x800<<12`)** 作上限判断；不是所有大二进制每次全量 hash。组件集排序后形成 identity（`0x10023c1d0`），root identity 区分 bundle/support/absolute（`0x10023b63c/0x10023b678/0x10023ba44`）。主程序也有一次性旧安装 bootstrap 标记 `CodexRuntimeIntegrityBootstrapV1`。这不是远端包签名验真替代品，不能描述为密码学全树防篡改。
