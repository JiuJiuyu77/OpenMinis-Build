//
//  NativeToolchain.swift
//  Minis — 原生编译工具链（不依赖 iSH）
//
//  背景：iSH 是为了在 App Store 沙盒里跑 Linux 才引入的模拟层。
//  本文件走另一条路：直接 posix_spawn 真正的 iOS Mach-O 工具链
//  （MT 运行时里的 Theos：clang / ld64 / dpkg-deb / ldid / bash）。
//
//  前提：App 必须带 platform-application / no-sandbox 权限
//  （TrollStore 或越狱安装）。没有权限时 isAvailable 返回 false，
//  上层会回退到 iSH，功能不回归。
//

import Foundation

struct NativeToolchain {

    static let shared = NativeToolchain()

    private static let cacheLock = NSLock()
    private static var cachedTheos: URL?? = nil
    private static var cachedShell: String?? = nil

    /// 工具链根目录（含 makefiles/common.mk 的那一层）。
    var theosRoot: URL? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cachedTheos { return cached }
        let found = Self.discoverTheos()
        Self.cachedTheos = found
        return found
    }

    /// 实际用来执行脚本的 shell。必须是 App 自带或运行时自带的 bash/sh ——
    /// 原厂 iOS 的 /bin/sh 行为受限，不能依赖。
    var shellPath: String? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cachedShell { return cached }
        let found = Self.discoverShell()
        Self.cachedShell = found
        return found
    }

    /// 真正的「可用」：找到 Theos 根 + 能执行 shell + 真的能找到 make。
    /// 只判断前两项会把「下载了一半的运行时目录」也算成已安装。
    var isAvailable: Bool {
        theosRoot != nil && shellPath != nil && findTool("make") != nil
    }

    /// 用户点了「重新检测」：清掉探测缓存。
    func resetCache() {
        Self.cacheLock.lock()
        Self.cachedTheos = nil
        Self.cachedShell = nil
        Self.cacheLock.unlock()
        Self.toolLock.lock()
        Self.toolCache.removeAll()
        Self.toolLock.unlock()
    }

    var rootPath: String { theosRoot?.path ?? "" }

    // MARK: - 诊断（工具链识别失败时手动修复用）

    /// 一次探测的逐项结果。设置页会把它直白地列出来，这样「找不到工具链」
    /// 不再是黑箱：能看出是没装、路径不对，还是只缺一个 shell。
    struct Diagnostics {
        struct Line {
            let title: String
            let detail: String
            let ok: Bool
        }

        var lines: [Line]
        var suggestedRoot: String?
        var usable: Bool
    }

    /// 探测全流程的诊断快照。廉价：只是若干次 fileExists。
    func diagnostics() -> Diagnostics {
        let fm = FileManager.default
        var lines: [Diagnostics.Line] = []

        let roots = Self.candidateRoots()
        let manual = Self.manualRootPath
        lines.append(.init(
            title: AppLocalized("Manual path"),
            detail: manual ?? AppLocalized("Not set"),
            ok: manual != nil))
        lines.append(.init(
            title: AppLocalized("Reuse external runtime"),
            detail: Self.reuseExternalRuntime
                ? AppLocalized("On — MT-Agent / CodexApp directories are scanned")
                : AppLocalized("Off — only runtimes installed in this app are used"),
            ok: true))

        var hitRoot: String?
        for root in roots {
            let exists = fm.fileExists(atPath: root.path)
            guard exists else { continue }
            if Self.looksLikeTheos(root) {
                let inner = root.appendingPathComponent("theos", isDirectory: true)
                let resolved = Self.looksLikeTheos(inner) ? inner : root
                hitRoot = resolved.path
                lines.append(.init(title: AppLocalized("Theos found"),
                                   detail: resolved.path,
                                   ok: true))
                break
            }
        }
        if hitRoot == nil {
            lines.append(.init(title: AppLocalized("Theos not found"),
                               detail: roots.prefix(6).map(\.path).joined(separator: "\n"),
                               ok: false))
        }

        let shell = shellPath
        lines.append(.init(title: AppLocalized("Shell"),
                           detail: shell ?? AppLocalized("No usable shell (bash/sh/zsh) was found"),
                           ok: shell != nil))

        if let root = theosRoot {
            let runtimeRoot = root.deletingLastPathComponent()
            let sdk = findSDK()
            lines.append(.init(title: AppLocalized("SDK"),
                               detail: sdk ?? AppLocalized("No .sdk directory under the Theos root"),
                               ok: sdk != nil))
            for tool in ["clang", "make", "ldid", "dpkg-deb"] {
                let found = findTool(tool)
                lines.append(.init(title: tool,
                                   detail: found ?? AppLocalized("Not found on PATH candidates"),
                                   ok: found != nil))
            }
            lines.append(.init(
                title: AppLocalized("Runtime bin"),
                detail: runtimeRoot.appendingPathComponent("usr/bin").path,
                ok: fm.fileExists(atPath: runtimeRoot.appendingPathComponent("usr/bin").path)))
            // 运行时常常只带 `clang-16`，没有裸 `clang`；shim 目录负责补链接。
            let shim = Self.shimDirectory?.path ?? ""
            lines.append(.init(
                title: AppLocalized("Tool shims"),
                detail: shim.isEmpty ? AppLocalized("Not available") : shim,
                ok: !shim.isEmpty && fm.fileExists(atPath: shim)))
        }

        return Diagnostics(lines: lines,
                           suggestedRoot: hitRoot ?? manual,
                           usable: isAvailable)
    }

    // MARK: - 探测

    /// 候选根目录，按优先级：
    /// 1. App 内置 `NativeToolchain/`（把运行时随包分发时用）
    /// 2. App 容器 `Library/Application Support/NativeToolchain/`
    /// 3. MT 智能体已下载的运行时（与 MT 共用一份，省 224MB）
    /// 用户是否要求「优先使用自定义 Runtime」。直接读 UserDefaults 而不是
    /// ToolExecutorPreference，因为这里是 nonisolated 的静态探测路径，
    /// 可能从后台队列被调用。
    static var prefersCustomRuntime: Bool {
        UserDefaults.standard.bool(forKey: "toolExecutor.preferCustomRuntime")
    }

    /// 是否扫描其它 App（MT-Agent / CodexApp）的运行时目录。默认关闭。
    /// 那些目录在沙箱构建里 mmap 不了，却会让「未安装 Theos」显示为已就绪。
    static var reuseExternalRuntime: Bool {
        UserDefaults.standard.bool(forKey: "nativeToolchain.reuseExternalRuntime")
    }

    /// 用户手动指定的工具链根目录（设置 → 执行器 → 工具链 → 手动指定）。
    /// 探测失败时的兜底：不猜布局，直接用用户给的路径。
    static let manualRootKey = "nativeToolchain.rootOverride"

    static var manualRootPath: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: manualRootKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            let trimmed = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: manualRootKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: manualRootKey)
            }
            shared.resetCache()
        }
    }

    /// MT 智能体在设备上的运行时目录（本 App 会复用这一份，省 224MB）。
    private static let mtRuntimeRoots = [
        "/var/mobile/Library/Application Support/CodexApp/PreparedRuntimes",
        "/var/mobile/Library/Application Support/CodexApp/RuntimeDownloads/Theos",
        "/var/mobile/Library/Application Support/CodexApp/RuntimeDownloads",
        "/var/mobile/Library/Application Support/CodexApp/ManagedRuntime",
    ]

    /// 候选根目录，按优先级：
    /// 0. 用户手动指定的路径（诊断失败时的兜底）
    /// 1. Developer Runtime 已安装的那份（勾了「优先使用自定义 Runtime」时提前）
    /// 2. App 内置 `NativeToolchain/`
    /// 3. App 容器 `Library/Application Support/NativeToolchain/`
    /// 4. MT 智能体的运行时目录（`PreparedRuntimes/*`、`RuntimeDownloads/*`）
    static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        if let manual = manualRootPath {
            roots.append(URL(fileURLWithPath: manual, isDirectory: true))
        }
        // [T-developer-runtime-prefer] 用户在设置里勾了「优先使用自定义
        // Runtime」时，Developer Runtime 装的那份排在最前面，优先于下面
        // MT-Agent 共用的那份。`installed/` 下每个运行时都是独立子目录，
        // 必须逐个子目录进候选，否则只扫到 `installed` 这一层就停了。
        let installed = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first?
            .appendingPathComponent("DeveloperRuntime/installed", isDirectory: true)
        if let installed {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: installed, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            let runtimeDirs = children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if prefersCustomRuntime {
                roots.append(contentsOf: runtimeDirs)
                roots.append(installed)
            } else {
                roots.append(contentsOf: runtimeDirs)
            }
        }
        roots.append(Bundle.main.bundleURL.appendingPathComponent("NativeToolchain", isDirectory: true))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("NativeToolchain", isDirectory: true))
            roots.append(support.appendingPathComponent("CodexApp", isDirectory: true))
        }
        // MT / CodexApp 的运行时目录默认不扫（见 reuseExternalRuntime）。
        // 用户明确勾选「复用外部运行时」后才作为候选。
        if reuseExternalRuntime {
            for path in mtRuntimeRoots {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                roots.append(url)
                // `PreparedRuntimes` 下同样是一层运行时子目录。
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                roots.append(contentsOf: children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                })
            }
        }
        roots.append(URL(fileURLWithPath: "/var/mobile/Library/Application Support/NativeToolchain"))
        // 去重，避免同一路径被 BFS 扫两次。
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func looksLikeTheos(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("makefiles/common.mk").path) { return true }
        let inner = url.appendingPathComponent("theos", isDirectory: true)
        return fm.fileExists(atPath: inner.appendingPathComponent("makefiles/common.mk").path)
    }

    /// 广度优先扫描（限制深度与节点数，避免在大目录里卡住首屏）。
    static func discoverTheos() -> URL? {
        for root in candidateRoots() {
            if looksLikeTheos(root) {
                let inner = root.appendingPathComponent("theos", isDirectory: true)
                return looksLikeTheos(inner) ? inner : root
            }
            if let hit = bfsTheos(from: root, maxDepth: 6) { return hit }
        }
        return nil
    }

    private static func bfsTheos(from root: URL, maxDepth: Int) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        let skip: Set<String> = [".git", "node_modules", "packages", "Caches", "tmp", "sdks"]

        while !queue.isEmpty && visited < 3000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            if looksLikeTheos(dir) {
                let inner = dir.appendingPathComponent("theos", isDirectory: true)
                return looksLikeTheos(inner) ? inner : dir
            }
            guard depth < maxDepth else { continue }
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if skip.contains(child.lastPathComponent) { continue }
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    /// Every shell path worth trying, best first. `NativeCommandRunner` walks
    /// this list after the preferred one fails: a runtime zsh that cannot
    /// resolve `@rpath/libiosexec.1.dylib` fails to exec, and the jailbreak's
    /// own bash still works.
    static func allShellCandidates() -> [String] {
        var candidates: [String] = []
        if let theos = discoverTheos() {
            let runtimeRoot = theos.deletingLastPathComponent()
            for rel in ["usr/bin/zsh", "usr/bin/bash", "usr/bin/dash", "usr/bin/sh",
                        "bin/zsh", "bin/bash", "bin/sh"] {
                candidates.append(runtimeRoot.appendingPathComponent(rel).path)
            }
        }
        candidates.append(contentsOf: [
            "/var/jb/usr/bin/bash",
            "/var/jb/usr/bin/zsh",
            "/var/jb/usr/bin/dash",
            "/var/jb/bin/sh",
            "/var/jb/usr/bin/sh",
            "/usr/bin/bash",
            "/usr/bin/zsh",
            "/bin/bash",
            "/bin/sh",
        ])
        let fm = FileManager.default
        var seen = Set<String>()
        // 截断/非 Mach-O 的 shell 直接排除：它只会让 posix_spawn 返回 EBADEXEC，
        // 然后在错误信息里伪装成「所有 shell 都启动不了」。
        return candidates.filter {
            fm.isExecutableFile(atPath: $0)
                && runtimeBinaryDamage($0) == nil
                && seen.insert($0).inserted
        }
    }

    private static func discoverShell() -> String? {
        let fm = FileManager.default
        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("NativeToolchain/bin/bash"))
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Helpers/bash.real"))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("NativeToolchain/bin/bash"))
        }
        // 运行时里自带的 shell 也可用。MT 的 Theos 运行时只带 zsh（没有 bash），
        // 之前只查 bash 会导致「工具链已装好但 isAvailable=false」。
        if let theos = discoverTheos() {
            let runtimeRoot = theos.deletingLastPathComponent()
            for rel in ["usr/bin/zsh", "usr/bin/bash", "usr/bin/sh", "bin/zsh", "bin/bash", "bin/sh"] {
                candidates.append(runtimeRoot.appendingPathComponent(rel))
                candidates.append(theos.appendingPathComponent(rel))
            }
            candidates.append(runtimeRoot.appendingPathComponent("Helpers/bash.real"))
        }
        // 手动指定根目录时也试一遍它下面的 shell。
        if let manual = manualRootPath {
            let root = URL(fileURLWithPath: manual, isDirectory: true)
            for rel in ["usr/bin/zsh", "usr/bin/bash", "usr/bin/sh", "bin/zsh", "bin/bash", "bin/sh"] {
                candidates.append(root.appendingPathComponent(rel))
            }
        }
        candidates.append(URL(fileURLWithPath: "/var/mobile/Library/Application Support/CodexApp/Helpers/bash.real"))
        candidates.append(URL(fileURLWithPath: "/var/jb/usr/bin/bash"))
        candidates.append(URL(fileURLWithPath: "/var/jb/usr/bin/zsh"))
        candidates.append(URL(fileURLWithPath: "/bin/sh"))
        // 注意：这里故意不排除损坏的 shell。发现阶段要能指出「就是它坏了」，
        // 真正 spawn 时的候选列表（allShellCandidates）才过滤损坏项。
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }?.path
    }

    // MARK: - 兼容层（补齐 clang / ld 这类“只有带版本号的可执行文件”的名字）

    /// 运行时里 clang 常常只有 `clang-16`，没有裸 `clang`；Theos 的 makefile
    /// 走 `CC=clang`、`LD=ld`，缺了就会在链接/编译时报“找不到命令”。这里在
    /// App 容器里建一个只含符号链接的目录，并把它放在 PATH 最前面。
    private static let shimLock = NSLock()
    private static var shimDirCache: String?

    static var shimDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("MinToolchainShim", isDirectory: true)
    }

    /// 需要保证存在的“裸名字”。值是可接受的带版本号别名顺序。
    private static let shimNames: [(String, [String])] = [
        ("clang", ["clang-16", "clang-17", "clang-15", "clang-18"]),
        ("clang++", ["clang++-16", "clang++-17", "clang++-15", "clang++-18"]),
        ("cc", ["clang-16", "clang-17"]),
        ("c++", ["clang++-16", "clang++-17"]),
        ("ld", ["ld64"]),
        ("ld64", ["ld64"]),
        ("ldid", ["ldid"]),
        ("dpkg-deb", ["dpkg-deb"]),
        ("make", ["make", "gmake"]),
        ("ar", ["ar"]),
        ("strip", ["strip"]),
    ]

    /// 在 `sourceDirs` 里找可执行文件，缺什么就在 shim 目录里补一个符号链接。
    /// 幂等、失败静默：补不上只是回到“找不到 clang”，不会更糟。
    @discardableResult
    static func prepareShims(sourceDirs: [String]) -> String? {
        guard let shim = shimDirectory else { return nil }
        let fm = FileManager.default
        Self.shimLock.lock()
        defer { Self.shimLock.unlock() }
        if let cached = shimDirCache, fm.fileExists(atPath: cached) { return cached }
        do {
            try fm.createDirectory(at: shim, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for (name, aliases) in shimNames {
            let target = shim.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: target.path) { continue }
            var resolved: String?
            for dir in sourceDirs {
                for candidate in [name] + aliases {
                    let p = (dir as NSString).appendingPathComponent(candidate)
                    if fm.isExecutableFile(atPath: p) { resolved = p; break }
                }
                if resolved != nil { break }
            }
            guard let resolved else { continue }
            try? fm.removeItem(at: target)
            try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: resolved)
        }
        shimDirCache = shim.path
        return shim.path
    }

    // MARK: - 环境

    /// 工具链内所有 bin 目录（PATH 前置用）。
    func searchPaths() -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        // 先把运行时的 bin 目录找出来，交给 shim 补 `clang`/`ld` 这类裸名字。
        if let root = theosRoot {
            let runtimeRoot = root.deletingLastPathComponent()
            let binDirs = ["usr/bin", "bin", "usr/local/bin", "toolchain/bin"]
                .map { runtimeRoot.appendingPathComponent($0).path }
                .filter { fm.fileExists(atPath: $0) }
            if let shim = Self.prepareShims(sourceDirs: binDirs) {
                paths.append(shim)
            }
        }
        if let root = theosRoot {
            for rel in ["bin", "toolchain/bin", "toolchain/usr/bin", "toolchain/linux/iphone/bin",
                        "toolchain/iphone/bin", "libexec/theos/bin"] {
                let p = root.appendingPathComponent(rel).path
                if fm.fileExists(atPath: p) { paths.append(p) }
            }
            // Theos checkout 位于 `<runtime>/theos`，而 clang / ld64 / ldid /
            // dpkg-deb 在 `<runtime>/usr/bin`。之前漏掉这一层，导致 make 能起
            // 来却找不到编译器。
            let runtimeRoot = root.deletingLastPathComponent()
            for rel in ["usr/bin", "bin", "usr/local/bin"] {
                let p = runtimeRoot.appendingPathComponent(rel).path
                if fm.fileExists(atPath: p) { paths.append(p) }
            }
        }
        // App 自带的 coreutils 替身（tar/cp/mv/mkdir… 都是同一个多合一二进制）
        for rel in ["NativeToolchain/bin", "Helpers", "Helpers/TheosCompat", "Helpers/TheosCoreCompat"] {
            let p = Bundle.main.bundleURL.appendingPathComponent(rel).path
            if fm.fileExists(atPath: p) { paths.append(p) }
        }
        paths.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"])
        return paths
    }

    private static let toolLock = NSLock()
    private static var toolCache: [String: String] = [:]

    /// 运行时内查找可执行文件（供 CA_THEOS_* 使用）。
    func findTool(_ name: String) -> String? {
        Self.toolLock.lock()
        if let hit = Self.toolCache[name] { Self.toolLock.unlock(); return hit }
        Self.toolLock.unlock()
        let found = searchTool(name)
        if let found {
            Self.toolLock.lock()
            Self.toolCache[name] = found
            Self.toolLock.unlock()
        }
        return found
    }

    /// 运行时里常见「装了带版本号的 clang，但没有 `clang` 这个符号链接」的
    /// 情况（MT 的 TheosRuntime 只有 `clang-16` / `clang++-16` / `clang-cpp-16`）。
    /// 编译器明明在，`CA_THEOS_CLANG=clang` 却解析不到，构建就会报“找不到
    /// clang”。这里为每个逻辑名准备一组可接受别名。
    private static let toolAliases: [String: [String]] = [
        "clang": ["clang-16", "clang-17", "clang-15", "clang-18", "clang-14", "clang-13"],
        "clang++": ["clang++-16", "clang++-17", "clang++-15", "clang++-18", "clang++-14"],
        "cc": ["clang-16", "clang"],
        "ld": ["ld64"],
        "ar": ["ar"],
    ]

    private func searchTool(_ name: String) -> String? {
        let fm = FileManager.default
        let names = [name] + (Self.toolAliases[name] ?? [])
        for dir in searchPaths() {
            for candidate in names {
                let p = (dir as NSString).appendingPathComponent(candidate)
                if fm.isExecutableFile(atPath: p) { return p }
            }
            // 最后兜底：目录里任意 `name-<数字>` 形式的可执行文件。
            if let entries = try? fm.contentsOfDirectory(atPath: dir) {
                for entry in entries where entry.hasPrefix(name + "-") {
                    let suffix = entry.dropFirst(name.count + 1)
                    if suffix.allSatisfy(\.isNumber) {
                        let p = (dir as NSString).appendingPathComponent(entry)
                        if fm.isExecutableFile(atPath: p) { return p }
                    }
                }
            }
        }
        guard let root = theosRoot else { return nil }
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 600 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            for candidate in names {
                let p = dir.appendingPathComponent(candidate).path
                if fm.isExecutableFile(atPath: p) { return p }
            }
            guard depth < 4 else { continue }
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children {
                if [".git", "share", "man", "include", "sdks"].contains(child.lastPathComponent) { continue }
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    /// 构造给子进程的环境。与 MT 的内嵌 Theos 约定保持一致，
    /// makefile 会走 theos-helper 的 forkless 分支。
    func environment(projectPath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths().joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        env["TMPDIR"] = NSTemporaryDirectory()
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["TERM"] = "dumb"

        if let root = theosRoot {
            env["THEOS"] = root.path
            env["CA_THEOS_RUNTIME"] = root.path
            env["CA_THEOS_PATH"] = root.path
            env["CA_THEOS_EMBEDDED"] = "1"
            if let sdk = findSDK() { env["SYSROOT"] = sdk; env["CA_THEOS_SDKROOT"] = sdk }
        }
        if let shell = shellPath { env["CA_THEOS_BASH"] = shell }

        // The runtime's zsh links `@rpath/libiosexec.1.dylib`, `@rpath/libpcre.1.dylib`
        // and `@rpath/libncursesw.6.dylib`, all shipped in `<runtime>/usr/lib`.
        // dyld resolves @rpath from LC_RPATH entries baked into the binary; if
        // those point nowhere the child dies inside dyld and posix_spawn looks
        // like a sandbox denial. DYLD_FALLBACK_LIBRARY_PATH is inherited by the
        // child and covers that case without patching the binary.
        var dylibPaths: [String] = []
        if let root = theosRoot {
            let runtimeRoot = root.deletingLastPathComponent()
            for rel in ["usr/lib", "lib", "usr/local/lib"] {
                let p = runtimeRoot.appendingPathComponent(rel).path
                if FileManager.default.fileExists(atPath: p) { dylibPaths.append(p) }
            }
        }
        dylibPaths.append(contentsOf: ["/var/jb/usr/lib", "/usr/lib"])
        env["DYLD_FALLBACK_LIBRARY_PATH"] = dylibPaths.joined(separator: ":")

        let helperCandidates = [Bundle.main.bundleURL.appendingPathComponent("Helpers/theos-helper"),
                                Bundle.main.bundleURL.appendingPathComponent("NativeToolchain/bin/theos-helper")]
        for h in helperCandidates where FileManager.default.isExecutableFile(atPath: h.path) {
            env["CA_THEOS_HELPER"] = h.path
            break
        }
        let tools: [String: String] = ["CA_THEOS_MAKE": "make", "CA_THEOS_CLANG": "clang",
                                       "CA_THEOS_CLANGXX": "clang++", "CA_THEOS_DPKG_DEB": "dpkg-deb",
                                       "CA_THEOS_TAR": "tar", "CA_THEOS_GZIP": "gzip",
                                       "CA_THEOS_XZ": "xz", "CA_THEOS_PERL": "perl"]
        for (key, tool) in tools {
            if let p = findTool(tool) { env[key] = p }
        }
        if let projectPath { env["MINIS_PROJECT"] = projectPath }
        return env
    }

    /// 找到 OLLVM 前端提供的 clang（带 `-mllvm -fla` 支持的那个）。
    ///
    /// 为什么需要单独找：「已安装 OLLVM」与「用什么编译器编」是两件事。
    /// 运行时把 OLLVM 前端放在自己的 `usr/bin`（通常叫 `clang` 或
    /// `clang-<ver>`），而 Theos 默认用运行时自带的 clang；如果 OLLVM 装在了
    /// 另一个运行时目录，就必须显式把编译器指过去，否则 `-mllvm` 参数会被
    /// 普通 clang 当成未知参数。
    func findObfuscatingClang() -> String? {
        let fm = FileManager.default
        var roots: [URL] = []
        if let installed = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first?
            .appendingPathComponent("DeveloperRuntime/installed", isDirectory: true),
           let children = try? fm.contentsOfDirectory(at: installed,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
            // 名字里含 ollvm 的优先，其余目录也会被扫到（提供就是 OLLVM）。
            roots.append(contentsOf: children.sorted {
                ($0.lastPathComponent.contains("ollvm") ? 0 : 1) <
                ($1.lastPathComponent.contains("ollvm") ? 0 : 1)
            })
        }
        for path in Self.mtRuntimeRoots {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            roots.append(url)
            if let children = try? fm.contentsOfDirectory(at: url,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) {
                roots.append(contentsOf: children)
            }
        }
        // 运行时自带的编译器也算候选（有些包把 OLLVM 直接换成了默认 clang）。
        if let root = theosRoot {
            roots.append(root.deletingLastPathComponent())
        }
        for root in roots {
            for binRel in ["usr/bin", "bin"] {
                let bin = root.appendingPathComponent(binRel, isDirectory: true)
                guard let entries = try? fm.contentsOfDirectory(atPath: bin.path) else { continue }
                for name in entries.sorted() where name == "clang" || name.hasPrefix("clang-") {
                    let full = bin.appendingPathComponent(name)
                    guard fm.isExecutableFile(atPath: full.path) else { continue }
                    if hasOLLVMPasses(full.path) { return full.path }
                }
            }
        }
        return nil
    }

    /// 二进制里出现 OLLVM 的 pass 名字就算带混淆支持。
    private func hasOLLVMPasses(_ binaryPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: binaryPath) else { return false }
        defer { try? handle.close() }
        let needle = Data("-fla".utf8)
        var carry = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            var hay = carry
            hay.append(chunk)
            if hay.range(of: needle) != nil { return true }
            carry = hay.count > 32 ? hay.suffix(32) : hay
        }
        return false
    }

    func findSDK() -> String? {
        let fm = FileManager.default
        guard let root = theosRoot else { return nil }
        for rel in ["sdks", "sdk", "theos/sdks", "toolchain/sdks"] {
            let dir = root.appendingPathComponent(rel, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if let sdk = names.first(where: { $0.hasSuffix(".sdk") }) {
                return dir.appendingPathComponent(sdk).path
            }
        }
        return nil
    }

    // MARK: - 工程识别

    enum ProjectKind: String {
        case theos = "Theos 插件工程"
        case make = "Makefile 工程"
        case xcode = "Xcode 工程"
        case unknown = "未识别"
    }

    func detectKind(_ path: String) -> ProjectKind {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let hasMakefile = names.contains { ["Makefile", "makefile", "GNUmakefile"].contains($0) }
        let hasXcode = names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        let hasTweakSource = names.contains { $0.hasSuffix(".x") || $0.hasSuffix(".xm") }
        let hasControl = names.contains("control") || fm.fileExists(atPath: (path as NSString).appendingPathComponent("layout"))
        if hasMakefile && (hasControl || hasTweakSource) { return .theos }
        if hasMakefile { return .make }
        if hasXcode { return .xcode }
        return .unknown
    }

    func artifacts(in projectPath: String) -> [String] {
        let fm = FileManager.default
        let pkg = (projectPath as NSString).appendingPathComponent("packages")
        var out: [String] = []
        for dir in [pkg, projectPath] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.lowercased().hasSuffix(".deb") {
                let full = (dir as NSString).appendingPathComponent(name)
                if !out.contains(full) { out.append(full) }
            }
        }
        return out.sorted { a, b in
            let da = (try? fm.attributesOfItem(atPath: a))?[.modificationDate] as? Date ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b))?[.modificationDate] as? Date ?? .distantPast
            return da > db
        }
    }
}
