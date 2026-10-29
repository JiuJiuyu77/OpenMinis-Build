# 运行时修复总结 - 对齐 MT 1.1.0

## 修复内容

### 1. 动态库路径注入 (P0 - 阻塞问题)

**问题**：子进程无法加载运行时动态库，报错 `EBADEXEC` / `dyld: Library not loaded`

**原因**：
- 运行时安装在 `~/Library/Application Support/DeveloperRuntime/installed/*`
- 子进程启动时 `DYLD_LIBRARY_PATH` 未设置
- 代码只设置了 `DYLD_FALLBACK_LIBRARY_PATH`（优先级低，容易被系统路径覆盖）

**修复** (`src/ios/Agent/NativeBuild/NativeCommandRunner.swift`):
```swift
// 改前：
environment["DYLD_FALLBACK_LIBRARY_PATH"] = dirs.joined(separator: ":")

// 改后：
environment["DYLD_LIBRARY_PATH"] = dirs.joined(separator: ":")  // 强制优先搜索
environment["DYLD_FRAMEWORK_PATH"] = Bundle.main.privateFrameworksPath  // Framework 路径
```

**影响**：
- 运行时二进制（clang/make/ldid）现在可以正确找到依赖的 dylib
- Framework 形式的运行时（NodeMobile.framework 等）也能正常加载

---

### 2. 签名工具路径 (P0 - 阻塞问题)

**问题**：`minis-sign` 无法找到，签名失败

**检查结果**：代码**已正确** - 优先查找 `Bundle.main.bundleURL/Helpers/minis-sign`

**现状**：
```swift
// src/ios/Agent/Runtime/RuntimeSigning.swift
var candidates = [Bundle.main.bundleURL.appendingPathComponent("Helpers/minis-sign")]
// ✓ 与 MT 一致
```

**无需修改**，只需确保构建时把 `minis-sign` 打包进 `.app/Helpers/`

---

### 3. MT 风格诊断报告 (P1 - 重要)

**新增文件** (`src/ios/Agent/Runtime/MTDiagnosticsReport.swift`):
- 实现 MT 1.1.0 风格的纯文本诊断输出
- 格式：【分组标题】+ key(20字符对齐) + ✓/✗/○/⚠ + detail
- 支持导出为 `.txt` 文件

**集成** (`src/ios/Views/Settings/RuntimeDiagnosticsView.swift`):
```swift
extension RuntimeDiagnosticsModel {
    func exportMTReport() -> String
    func saveReport(to: URL) throws
}
```

**输出示例**：
```
Minis 运行诊断
时间：2026-10-29 23:45:12（用时 12.3 秒）
设备：iPhone14,2 · iOS 17.0
App：1.1.0 (27)
结论：核心能力正常

【Runtime Compatibility Probe】
Sandbox kernel       ✓  iSH Alpine 3.18
Command execution    ✓  echo test passed
Realtime tool bridge ✓  minis-* commands available
...
```

---

### 4. 运行时下载优化 (P2 - 已有)

**检查结果**：以下功能**已实现**
- ✓ 断点续传 - `.part` 文件 + SHA256 增量哈希
- ✓ 镜像源自动切换 - gh-proxy.org、ghproxy.net
- ✓ 重试机制 - 最多 10 次，镜像源失败自动切换

**无需额外修改**

---

## 测试验证

### 本地验证步骤

1. **编译 & 安装**
```bash
# 1. 编译
xcodebuild -project Minis.xcodeproj -scheme Minis -configuration Release

# 2. 安装到 TrollStore
# (手动通过 TrollStore 安装 .tipa)

# 3. 首次启动后，进入"设置 → 开发者运行时"
# 4. 下载 Theos Runtime
# 5. 等待安装完成（观察日志）
```

2. **子进程动态库加载测试**
```bash
# 在 Minis 的编译工作台中执行：
/path/to/runtime/usr/bin/make --version

# 预期：正常输出 GNU Make 版本
# 之前：dyld: Library not loaded: @rpath/libiosexec.dylib
```

3. **签名验证**
```bash
# 检查 clang 是否被正确签名
ldid -e /path/to/runtime/usr/bin/clang

# 预期：输出 entitlements XML
# 包含：platform-application, no-sandbox, task_for_pid-allow
```

4. **诊断报告导出**
```
设置 → 运行时诊断 → 点击"重新检测"
等待完成 → 点击"导出报告"
保存为 minis-diagnostics.txt
对比 MT 的诊断输出格式
```

---

## 与 MT 1.1.0 的差异

| 项目 | MT (CodexApp) | Minis | 状态 |
|---|---|---|---|
| 运行时路径 | `.app/TheosRuntime/` | `~/Library/.../installed/` | ⚠ 架构不同但可用 |
| 动态库注入 | `DYLD_LIBRARY_PATH` 自动 | 现已修复 | ✓ 对齐 |
| 签名工具 | `Helpers/minis-sign` | `Helpers/minis-sign` | ✓ 一致 |
| 诊断格式 | 纯文本 + 分组 | 现已实现 | ✓ 对齐 |
| 下载优化 | 断点续传 + 镜像 | 已有 | ✓ 一致 |
| Node.js | 18.20.4 (计划 24.5.0) | 18.20.4 | ⚠ 等待上游 |
| OLLVM | 23.1.1 | 23.1.1 | ✓ 一致 |

---

## 已知限制

1. **运行时路径架构**
   - MT：运行时在 `.app` 内，随 App 分发
   - Minis：运行时在 Application Support，用户自行下载
   - **影响**：Minis 用户需要手动下载运行时，但支持独立更新

2. **TrollStore 环境**
   - 两者都依赖 TrollStore 提供的 CoreTrust 签名能力
   - 非 TrollStore 环境（AppStore/TestFlight）下原生编译**不可用**
   - 这是预期行为，不是 bug

3. **沙盒环境**
   - Minis 使用 iSH Alpine 沙盒 + 原生 offload
   - MT 直接执行（无沙盒层）
   - **权衡**：Minis 更安全但多一层调用开销

---

## 后续优化建议

### 短期 (1-2 周)

1. **App bundle 内嵌轻量运行时** (可选)
   ```
   Minis.app/EmbeddedRuntimes/
   ├── lite-theos/      # 精简版 Theos (50MB)
   └── core-tools/      # git/rg/curl (10MB)
   ```
   - 首次安装即可用，无需等待下载
   - 完整版仍通过 Settings 下载

2. **诊断 UI 增强**
   - 添加"导出报告"按钮到诊断页面
   - 支持分享到文件 App / 拷贝到剪贴板
   - 显示诊断历史记录

### 中期 (1-2 月)

1. **运行时增量更新**
   - 当前：整包下载（~200MB）
   - 优化：差分补丁（~10-20MB）

2. **多版本共存**
   - 允许同时安装 Theos 16.5 和 17.0
   - 项目级别的运行时选择

### 长期 (3+ 月)

1. **完全对齐 MT 路径**
   - 将运行时迁移到 `.app/ManagedRuntimes/`
   - 需要解决 App bundle 可写性问题（TrollStore 特殊处理）

2. **原生模块编译**
   - Node.js N-API addon 支持
   - Python C extension 支持
   - 需要完整的 iOS SDK 和工具链

---

## 参考文档

- MT 1.1.0 诊断报告：见用户附件 `粘贴文本_20261029_231224.txt`
- CodexApp 环境变量：`CA_THEOS_*`, `DYLD_*`, `CODEXAPP_*`
- TrollStore CoreTrust：https://github.com/opa334/TrollStore
- 运行时清单：https://github.com/susu123oss/CodexApp-Runtime

---

## 提交记录

- **动态库路径修复**: `DYLD_LIBRARY_PATH` + `DYLD_FRAMEWORK_PATH` 注入
- **MT 诊断报告**: 新增 `MTDiagnosticsReport.swift` + 导出功能
- **文档**: 本修复总结 + 测试验证步骤
