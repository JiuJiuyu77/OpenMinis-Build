# MT 诊断逻辑还原与运行时修复方案

## 问题分析

根据 MT 1.1.0 诊断报告和 OpenMinis-Build 代码对比，发现以下关键差异：

### 1. 运行时路径架构差异

**MT (CodexApp)**：
```
CodexApp.app/
├── TheosRuntime/          # 直接在 .app 内
├── ManagedRuntimes/       # 直接在 .app 内
├── PythonRuntime/         # 直接在 .app 内
└── ReverseTools/          # 直接在 .app 内
```

**Minis (当前)**：
```
~/Library/Application Support/DeveloperRuntime/installed/
├── theos-something/
├── node-something/
└── ...
```

**问题**：
- 运行时不在 .app 内 → 子进程无法通过相对路径找到动态库
- Application Support 目录在沙盒外 → TrollStore 环境下可能无法访问
- 没有 fallback 到 .app bundle 内的机制

### 2. 动态库加载路径

**MT**：所有运行时在 .app 内 → `DYLD_LIBRARY_PATH` 自动包含
**Minis**：运行时在外部 → 需要显式设置 `DYLD_LIBRARY_PATH` 但代码中缺失

### 3. 签名工具路径

**MT**: 
```swift
// minis-sign 在 App bundle Helpers/
candidates.append(Bundle.main.bundleURL.appendingPathComponent("Helpers/minis-sign"))
```

**Minis (当前)**:
```swift
// 只查找 Application Support，不查 App bundle
candidates.append(DeveloperRuntimePaths.root.appendingPathComponent("Helpers/minis-sign"))
```

### 4. 诊断日志格式

**MT 输出格式**：
```
【Runtime Compatibility Probe】
CLI Ready: ✓    Runtime Ready: ✓    Upstream Ready: ✓

persona API      ✓
root persona     ✓
effective uid=0  ✓
...
```

**Minis 当前**：只有简单的 SwiftUI 状态，没有完整的文本报告导出

## 修复方案

### 方案 A：混合路径（推荐）

保留当前的 Application Support 安装，但添加 App bundle fallback：

1. **运行时发现逻辑增强**：
   ```swift
   // 1. Application Support/DeveloperRuntime/installed/* (用户安装)
   // 2. App.app/EmbeddedRuntimes/* (预装/轻量)
   // 3. App.app/Frameworks/*.framework/Resources/Runtime (framework 打包)
   ```

2. **动态库路径注入**：
   ```swift
   var environment = ProcessInfo.processInfo.environment
   let runtimeLibs = [
       "\(runtimeRoot)/usr/lib",
       "\(runtimeRoot)/usr/local/lib",
       Bundle.main.bundleURL.appendingPathComponent("Frameworks").path
   ]
   environment["DYLD_LIBRARY_PATH"] = runtimeLibs.joined(separator: ":")
   ```

3. **签名工具查找顺序**：
   ```swift
   candidates.append(Bundle.main.bundleURL.appendingPathComponent("Helpers/minis-sign"))
   candidates.append(DeveloperRuntimePaths.root.appendingPathComponent("Helpers/minis-sign"))
   candidates.append(URL(fileURLWithPath: "/var/jb/usr/bin/minis-sign"))
   ```

### 方案 B：完全迁移到 .app 内（MT 模式）

将运行时安装到 `.app/ManagedRuntimes/` 内：

**优点**：
- 与 MT 完全一致
- 无需外部路径权限
- 动态库自动可见

**缺点**：
- 需要修改 App bundle（TrollStore 可以，但 TestFlight/AppStore 不行）
- 更新 runtime 需要重新打包整个 App
- 磁盘占用更大（.app 会被系统备份）

## 实施步骤

### Step 1: 增强运行时发现（RuntimeEnvironment.swift）

```swift
static func candidateRuntimeRoots() -> [URL] {
    var candidates: [URL] = []
    let fm = FileManager.default
    
    // 1. 用户安装的运行时 (Application Support)
    if let installed = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("DeveloperRuntime/installed", isDirectory: true) {
        candidates += (try? fm.contentsOfDirectory(at: installed, ...)) ?? []
    }
    
    // 2. App 内嵌运行时 (新增)
    if let embedded = Bundle.main.url(forResource: "EmbeddedRuntimes", withExtension: nil) {
        candidates += (try? fm.contentsOfDirectory(at: embedded, ...)) ?? []
    }
    
    // 3. Frameworks 内的运行时资源 (新增)
    let frameworks = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    if let fwChildren = try? fm.contentsOfDirectory(at: frameworks, ...) {
        for fw in fwChildren where fw.pathExtension == "framework" {
            let runtime = fw.appendingPathComponent("Resources/Runtime")
            if fm.fileExists(atPath: runtime.path) {
                candidates.append(runtime)
            }
        }
    }
    
    return candidates
}
```

### Step 2: 动态库路径注入（NativeCommandRunner.swift）

```swift
func buildEnvironment(runtimeRoot: URL) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    
    // 动态库搜索路径
    var libPaths: [String] = []
    libPaths.append("\(runtimeRoot.path)/usr/lib")
    libPaths.append("\(runtimeRoot.path)/usr/local/lib")
    libPaths.append("\(runtimeRoot.path)/lib")
    
    // App Frameworks (签名过的动态库)
    libPaths.append(Bundle.main.bundleURL.appendingPathComponent("Frameworks").path)
    
    // 保留已有的 DYLD_LIBRARY_PATH
    if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
        libPaths.append(existing)
    }
    
    env["DYLD_LIBRARY_PATH"] = libPaths.joined(separator: ":")
    env["DYLD_FRAMEWORK_PATH"] = Bundle.main.privateFrameworksPath ?? ""
    
    return env
}
```

### Step 3: 签名工具路径修复（RuntimeSigning.swift）

```swift
static func findSigningTool() -> URL? {
    var candidates: [URL] = []
    
    // 1. App bundle Helpers/ (最优先，与 MT 一致)
    candidates.append(Bundle.main.bundleURL.appendingPathComponent("Helpers/minis-sign"))
    
    // 2. Application Support
    candidates.append(DeveloperRuntimePaths.root.appendingPathComponent("Helpers/minis-sign"))
    
    // 3. 系统路径 (越狱环境)
    candidates.append(URL(fileURLWithPath: "/var/jb/usr/bin/minis-sign"))
    candidates.append(URL(fileURLWithPath: "/usr/bin/minis-sign"))
    
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
```

### Step 4: MT 风格诊断报告生成

```swift
struct MTDiagnosticsReport {
    let timestamp: Date
    let elapsed: TimeInterval
    let device: String
    let appVersion: String
    let conclusion: String
    
    var sections: [Section]
    
    struct Section {
        let title: String
        var items: [Item]
    }
    
    struct Item {
        let key: String
        let status: Status
        let detail: String?
        
        enum Status {
            case ok, warning, failed, skipped
            
            var symbol: String {
                switch self {
                case .ok: return "✓"
                case .warning: return "⚠"
                case .failed: return "✗"
                case .skipped: return "○"
                }
            }
        }
    }
    
    func formatted() -> String {
        var lines: [String] = []
        lines.append("Minis 运行诊断")
        lines.append("时间：\(timestamp formatted as yyyy-MM-dd HH:mm:ss)（用时 \(elapsed formatted) 秒）")
        lines.append("设备：\(device)")
        lines.append("App：\(appVersion)")
        lines.append("结论：\(conclusion)")
        lines.append("")
        
        for section in sections {
            lines.append("【\(section.title)】")
            for item in items {
                let statusLine = "\(item.key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(item.status.symbol)"
                lines.append(statusLine + (item.detail.map { "  \($0)" } ?? ""))
            }
            lines.append("")
        }
        
        return lines.joined(separator: "\n")
    }
}
```

### Step 5: 运行时下载优化

```swift
class RuntimeDownloader {
    // 1. 分段下载 + 断点续传
    func resumableDownload(from url: URL, to destination: URL) async throws {
        let resumeData = try? Data(contentsOf: destination.appendingPathExtension("resume"))
        // URLSession with resumeData
    }
    
    // 2. CDN 多源切换
    static let mirrors = [
        "https://github.com/.../releases/download",
        "https://mirror.ghproxy.com/.../releases/download",
        "https://cdn.jsdelivr.net/gh/.../releases/download"
    ]
    
    // 3. 并行下载多个 chunk
    func parallelDownload(urls: [URL]) async throws {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { try await self.downloadChunk(url, index: index) }
            }
            // merge chunks
        }
    }
}
```

## 测试验证

1. **路径测试**：
   ```bash
   # 验证运行时被正确发现
   lldb --batch -o "process attach --name Minis" -o "expr -- MinisRuntimeEnvironment.candidateRuntimeRoots()"
   ```

2. **动态库加载测试**：
   ```bash
   # 子进程能否加载 libiosexec.dylib
   DYLD_PRINT_LIBRARIES=1 /path/to/runtime/usr/bin/make --version
   ```

3. **签名验证**：
   ```bash
   codesign -dvvv /path/to/runtime/usr/bin/clang
   ldid -e /path/to/runtime/usr/bin/make
   ```

4. **完整诊断**：
   ```
   设置 → 运行时诊断 → 点击"重新检测" → 导出报告
   对比 MT 的诊断输出格式
   ```

## 优先级

**P0 (阻塞)**：
- [ ] 签名工具路径修复 (Step 3)
- [ ] 动态库路径注入 (Step 2)

**P1 (重要)**：
- [ ] 运行时发现增强 (Step 1)
- [ ] MT 风格诊断报告 (Step 4)

**P2 (优化)**：
- [ ] 运行时下载优化 (Step 5)
- [ ] 嵌入式运行时支持

## 参考

- MT 1.1.0 诊断报告：见附件
- CodexApp 环境变量映射：CA_THEOS_*, CA_TOOL_*, DYLD_*
- TrollStore CoreTrust 签名：minis-sign 实现
