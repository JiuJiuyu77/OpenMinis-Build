//
//  NativeToolchain.swift
//  Minis — 原生编译工具链（不依赖 iSH）
//
//  背景：iSH 是为了在 App Store 沙盒里跑 Linux 才引入的模拟层。
//  本文件走另一条路：直接 posix_spawn 真正的 iOS Mach-O 工具链
//  （MT 运行时里的 Theos：clang / ld64 / dpkg-deb / ldid / bash）。
//
//  原生执行依赖安装权限与有效签名；isAvailable 仅判断文件布局。
//  真实执行能力由 NativeRuntimeHealthMonitor 探测，上层保留 iSH 回退。
//

import Foundation

struct NativeToolchain {

    static let shared = NativeToolchain()

    private static let cacheLock = NSLock()
    private static var cachedTheos: URL?? = nil
    private static var cachedShell: String?? = nil
    private static var cachedRuntimeState: String?
    private static var cacheGeneration: UInt64 = 0

    /// Atomic install swaps/record updates must invalidate negative discoveries too.
    /// Read only our own runtime metadata; never enumerate another app's container.
    private static var runtimeState: String {
        var urls = [DeveloperRuntimePaths.installedRoot, DeveloperRuntimePaths.recordsURL,
                    DeveloperRuntimePaths.root.appendingPathComponent("manifest.json"),
                    Bundle.main.bundleURL.appendingPathComponent("NativeToolchain")]
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appendingPathComponent("NativeToolchain"))
        }
        if let manual = manualRootPath {
            let root = URL(fileURLWithPath: manual)
            urls.append(contentsOf: [root, root.appendingPathComponent("makefiles/common.mk")])
        }
        return (urls.map { url in
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path):\(stamp):\(attrs[.systemFileNumber] ?? 0):\(attrs[.size] ?? 0)"
        } + [manualRootPath ?? ""]).joined(separator: "|")
    }

    private static func refreshCachesIfNeeded() {
        let state = runtimeState
        cacheLock.lock()
        let changed = cachedRuntimeState != state
        if changed {
            cachedRuntimeState = state
            cachedTheos = nil
            cachedShell = nil
            cacheGeneration &+= 1
        }
        cacheLock.unlock()
        if changed {
            toolLock.lock()
            toolCache.removeAll()
            toolLock.unlock()
        }
    }

    /// Health results are valid only for the discovery generation they tested.
    var generation: UInt64 {
        Self.refreshCachesIfNeeded()
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        return Self.cacheGeneration
    }

    /// 工具链根目录（含 makefiles/common.mk 的那一层）。
    var theosRoot: URL? {
        Self.refreshCachesIfNeeded()
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
        Self.refreshCachesIfNeeded()
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.cachedShell { return cached }
        let found = Self.discoverShell()
        Self.cachedShell = found
        return found
    }

    /// 文件布局可用：Theos + shell + make 均存在；不代表它们能成功启动。
    /// 实际执行能力由 NativeRuntimeHealthMonitor 的 shell + make 探针确认。
    var isAvailable: Bool {
        theosRoot != nil && shellPath != nil && findTool("make") != nil
    }

    /// 用户点了「重新检测」：清掉探测缓存。
    func resetCache() {
        Self.cacheLock.lock()
        Self.cachedTheos = nil
        Self.cachedShell = nil
        Self.cachedRuntimeState = nil
        Self.cacheGeneration &+= 1
        Self.cacheLock.unlock()
        Self.toolLock.lock()
        Self.toolCache.removeAll()
        Self.toolLock.unlock()
        Self.overlayLock.lock()
        Self.overlayCache = nil
        Self.overlayLock.unlock()
    }

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
            let runtimeRoot = Self.runtimeRoot(forTheos: root)
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

    /// 候选根目录，按优先级：
    /// 0. 用户手动指定的路径（诊断失败时的兜底）
    /// 1. Developer Runtime 已安装的运行时（每个子目录都是一个独立根）
    /// 2. App 内置 `NativeToolchain/`
    /// 3. App 容器 `Library/Application Support/NativeToolchain/`
    ///
    /// 不再扫别的 App（MT-Agent / CodexApp）的运行时目录：本 App 装的运行时
    /// 自己自检、自己签名，借对方的目录只会带来 mmap 失败与假「已就绪」。
    static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        if let manual = manualRootPath {
            roots.append(URL(fileURLWithPath: manual, isDirectory: true))
        }
        // `installed/` 下每个运行时都是独立子目录，必须逐个子目录进候选，
        // 否则只扫到 `installed` 这一层就停了。
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
            roots.append(contentsOf: runtimeDirs.filter { !RuntimeDescriptor.isAgentIdentifier($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        roots.append(Bundle.main.bundleURL.appendingPathComponent("NativeToolchain", isDirectory: true))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("NativeToolchain", isDirectory: true))
        }
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Installed tools must work without a Theos checkout. Consume the same
    /// manifest overlay as the installer (including its environment/path contract).
    /// This synchronous snapshot is safe for native/offload background callers;
    /// it never crosses DeveloperRuntimeManager's MainActor boundary.
    private static let overlayLock = NSLock()
    private static var overlayCache: (state: String, result: RuntimeEnvironmentOverlay.Result)?

    private static func installedEnvironment() -> RuntimeEnvironmentOverlay.Result {
        let state = runtimeState
        overlayLock.lock()
        defer { overlayLock.unlock() }
        if let cached = overlayCache, cached.state == state { return cached.result }
        let fm = FileManager.default
        let manifestURL = DeveloperRuntimePaths.root.appendingPathComponent("manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap {
            try? JSONDecoder().decode(RuntimeManifest.self, from: $0)
        }
        let roots = ((try? fm.contentsOfDirectory(at: DeveloperRuntimePaths.installedRoot,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var exports: [String: String] = [:]
        var paths: [String] = []
        for root in roots {
            let id = root.lastPathComponent
            guard !RuntimeDescriptor.isAgentIdentifier(id),
                  (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if var descriptor = manifest?.runtimes[id] {
                descriptor.id = id
                guard descriptor.isSupportedRuntime, descriptor.installationIssue == nil else { continue }
                let overlay = RuntimeEnvironmentOverlay.build(descriptor: descriptor, root: root)
                exports.merge(overlay.exports) { current, _ in current }
                paths.append(contentsOf: overlay.pathEntries)
            } else {
                // Offline/legacy installation without a cached central manifest.
                exports["CA_TOOL_\(RuntimeEnvironmentOverlay.envelopeKey(id))_RUNTIME_ROOT"] = root.path
                for rel in ["usr/bin", "bin"] {
                    let path = root.appendingPathComponent(rel).path
                    if fm.fileExists(atPath: path) { paths.append(path) }
                }
            }
        }
        let result = RuntimeEnvironmentOverlay.Result(exports: exports, pathEntries: uniquePaths(paths))
        overlayCache = (state, result)
        return result
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Both archive layouts are supported: <runtime>/theos and a flat checkout.
    static func runtimeRoot(forTheos root: URL) -> URL {
        let parent = root.deletingLastPathComponent()
        if root.lastPathComponent == "theos" {
            let fm = FileManager.default
            let hasRuntimeLayout = ["usr", "bin", "manifest.json", ".runtime-record.json"].contains {
                fm.fileExists(atPath: parent.appendingPathComponent($0).path)
            }
            if hasRuntimeLayout { return parent }
        }
        return root
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
            candidates.append(contentsOf: shellPaths(in: runtimeRoot(forTheos: theos)))
            candidates.append(contentsOf: shellPaths(in: theos))
        }
        for root in candidateRoots() {
            candidates.append(contentsOf: shellPaths(in: root))
        }
        for rel in ["Helpers/bash.real", "Helpers/bash", "Helpers/sh"] {
            candidates.append(Bundle.main.bundleURL.appendingPathComponent(rel).path)
        }
        // Keep system/jailbreak fallbacks: they may work when runtime zsh's dyld fails.
        candidates.append(contentsOf: [
            "/var/jb/usr/bin/bash", "/var/jb/usr/bin/zsh", "/var/jb/usr/bin/dash",
            "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/usr/bin/bash", "/usr/bin/zsh",
            "/bin/bash", "/bin/sh",
        ])
        let executable = uniquePaths(candidates).filter { FileManager.default.isExecutableFile(atPath: $0) }
        let healthy = executable.filter {
            runtimeBinaryDamage(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) == nil
        }
        // Keep damaged paths in diagnostics only if no healthy shell exists.
        return healthy.isEmpty ? executable : healthy
    }

    private static func shellPaths(in root: URL) -> [String] {
        ["usr/bin/zsh", "usr/bin/bash", "usr/bin/dash", "usr/bin/sh",
         "bin/zsh", "bin/bash", "bin/dash", "bin/sh", "Helpers/bash.real"]
            .map { root.appendingPathComponent($0).path }
    }

    private static func discoverShell() -> String? {
        allShellCandidates().first
    }

    // MARK: - 兼容层（补齐 clang / ld 这类“只有带版本号的可执行文件”的名字）

    /// 运行时里 clang 常常只有 `clang-16`，没有裸 `clang`；Theos 的 makefile
    /// 走 `CC=clang`、`LD=ld`，缺了就会在链接/编译时报“找不到命令”。这里在
    /// App 容器里建一个只含符号链接的目录，并把它放在 PATH 最前面。
    private static let shimLock = NSLock()

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
        do {
            try fm.createDirectory(at: shim, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for (name, aliases) in shimNames {
            let target = shim.appendingPathComponent(name)
            var resolved: String?
            for dir in sourceDirs {
                for candidate in [name] + aliases {
                    let p = (dir as NSString).appendingPathComponent(candidate)
                    if fm.isExecutableFile(atPath: p) { resolved = p; break }
                }
                if resolved != nil { break }
            }
            let existing = try? fm.destinationOfSymbolicLink(atPath: target.path)
            // Only manage our symlinks, never delete an unexpected regular file.
            if existing == resolved, resolved != nil { continue }
            if existing != nil { try? fm.removeItem(at: target) }
            guard let resolved, !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: resolved)
        }
        return shim.path
    }

    // MARK: - 环境

    /// 工具链内所有 bin 目录（PATH 前置用）。
    func searchPaths() -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        if let root = theosRoot {
            for rel in ["bin", "toolchain/bin", "toolchain/usr/bin", "toolchain/linux/iphone/bin",
                        "toolchain/iphone/bin", "libexec/theos/bin"] {
                let p = root.appendingPathComponent(rel).path
                if fm.fileExists(atPath: p) { paths.append(p) }
            }
            // Theos checkout 位于 `<runtime>/theos`，而 clang / ld64 / ldid /
            // dpkg-deb 在 `<runtime>/usr/bin`。之前漏掉这一层，导致 make 能起
            // 来却找不到编译器。
            let runtimeRoot = Self.runtimeRoot(forTheos: root)
            for rel in ["usr/bin", "bin", "usr/local/bin", "usr/lib/llvm-16/bin"] {
                let p = runtimeRoot.appendingPathComponent(rel).path
                if fm.fileExists(atPath: p) { paths.append(p) }
            }
        }
        paths.append(contentsOf: Self.installedEnvironment().pathEntries)
        paths = Self.uniquePaths(paths)
        // OLLVM remains opt-in: Theos' ordinary compiler precedes other runtimes.
        if let shim = Self.prepareShims(sourceDirs: paths) { paths.insert(shim, at: 0) }
        // App 自带的 coreutils 替身（tar/cp/mv/mkdir… 都是同一个多合一二进制）
        for rel in ["NativeToolchain/bin", "Helpers", "Helpers/TheosCompat", "Helpers/TheosCoreCompat"] {
            let p = Bundle.main.bundleURL.appendingPathComponent(rel).path
            if fm.fileExists(atPath: p) { paths.append(p) }
        }
        paths.append(contentsOf: ["/var/jb/usr/bin", "/var/jb/bin", "/usr/bin", "/bin",
                                  "/usr/sbin", "/sbin", "/usr/local/bin"])
        return Self.uniquePaths(paths)
    }

    private static let toolLock = NSLock()
    private static var toolCache: [String: String] = [:]

    /// 运行时内查找可执行文件（供 CA_THEOS_* 使用）。
    func findTool(_ name: String) -> String? {
        Self.refreshCachesIfNeeded()
        Self.toolLock.lock()
        if let hit = Self.toolCache[name], FileManager.default.isExecutableFile(atPath: hit) {
            Self.toolLock.unlock()
            return hit
        }
        Self.toolCache[name] = nil
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

    /// 构造原生子进程环境；复用清单 overlay，不启用 MT 私有 forkless helper。
    func environment(projectPath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let overlay = Self.installedEnvironment()
        env.merge(overlay.exports) { _, installed in installed }
        let inheritedPaths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let paths = Self.uniquePaths(searchPaths() + inheritedPaths)
        env["PATH"] = paths.joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        env["TMPDIR"] = NSTemporaryDirectory()
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["TERM"] = "dumb"
        let certificate = Bundle.main.url(forResource: "cacert", withExtension: "pem")
            ?? Bundle.main.url(forResource: "cacert", withExtension: "pem", subdirectory: "Helpers")
        if let certificate {
            for key in ["SSL_CERT_FILE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO", "NODE_EXTRA_CA_CERTS"]
                where env[key]?.isEmpty != false {
                env[key] = certificate.path
            }
        }

        if let root = theosRoot {
            env["THEOS"] = root.path
            env["CA_THEOS_RUNTIME"] = Self.runtimeRoot(forTheos: root).path
            env["CA_THEOS_PATH"] = paths.joined(separator: ":")
            // We ship unpatched upstream makefiles and no private packaging helper.
            // Native make/package must use ordinary external tools, not MT's forkless ABI.
            env["CA_THEOS_EMBEDDED"] = "0"
            env["CA_THEOS_HELPER"] = nil
            env["CA_THEOS_PACKAGE_MODE"] = nil
            if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("NativeToolchain/ModuleCache", isDirectory: true) {
                if (try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)) != nil {
                    env["CA_THEOS_MODULE_CACHE"] = cache.path
                    env["CLANG_MODULE_CACHE_PATH"] = cache.path
                }
            }
            if let sdk = findSDK() {
                env["SYSROOT"] = sdk
                env["SDKROOT"] = sdk
                env["CA_THEOS_SDKROOT"] = sdk
                env["THEOS_SDKROOT"] = URL(fileURLWithPath: sdk).deletingLastPathComponent().path
            }
        }
        if let shell = shellPath {
            env["SHELL"] = shell
            env["CONFIG_SHELL"] = shell
            env["CA_THEOS_BASH"] = shell
        }

        // The runtime's zsh links `@rpath/libiosexec.1.dylib`, `@rpath/libpcre.1.dylib`
        // and `@rpath/libncursesw.6.dylib`, all shipped in `<runtime>/usr/lib`.
        // dyld resolves @rpath from LC_RPATH entries baked into the binary; if
        // those point nowhere the child dies inside dyld and posix_spawn looks
        // like a sandbox denial. DYLD_FALLBACK_LIBRARY_PATH is inherited by the
        // child and covers that case without patching the binary.
        var dylibPaths: [String] = []
        if let root = theosRoot {
            let runtimeRoot = Self.runtimeRoot(forTheos: root)
            for rel in ["usr/lib", "lib", "usr/local/lib"] {
                let p = runtimeRoot.appendingPathComponent(rel).path
                if FileManager.default.fileExists(atPath: p) { dylibPaths.append(p) }
            }
        }
        for (key, value) in overlay.exports where key.hasPrefix("CA_TOOL_") && key.hasSuffix("_RUNTIME_ROOT") {
            let root = URL(fileURLWithPath: value)
            for rel in ["usr/lib", "lib", "usr/local/lib"] {
                let path = root.appendingPathComponent(rel).path
                if FileManager.default.fileExists(atPath: path) { dylibPaths.append(path) }
            }
        }
        dylibPaths.append(contentsOf: (env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "").split(separator: ":").map(String.init))
        dylibPaths.append(contentsOf: ["/var/jb/usr/lib", "/usr/lib"])
        env["DYLD_FALLBACK_LIBRARY_PATH"] = Self.uniquePaths(dylibPaths).joined(separator: ":")

        let tools: [String: String] = ["CA_THEOS_MAKE": "make", "CA_THEOS_CLANG": "clang",
                                       "CA_THEOS_CLANGXX": "clang++", "CA_THEOS_DPKG_DEB": "dpkg-deb",
                                       "CA_THEOS_TAR": "tar", "CA_THEOS_GZIP": "gzip",
                                       "CA_THEOS_XZ": "xz", "CA_THEOS_PERL": "perl",
                                       "CA_THEOS_ZSH": "zsh",
                                       "CA_THEOS_LINKER": "ld64", "CA_THEOS_LDID": "ldid",
                                       "CA_THEOS_AR": "ar", "CA_THEOS_STRIP": "strip",
                                       "CA_THEOS_LIPO": "lipo", "CA_THEOS_NM": "nm-classic"]
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
            roots.append(contentsOf: children.filter { $0.lastPathComponent != "codex" }.sorted {
                let lhs = $0.lastPathComponent.lowercased().contains("ollvm")
                let rhs = $1.lastPathComponent.lowercased().contains("ollvm")
                return lhs != rhs ? lhs : $0.lastPathComponent < $1.lastPathComponent
            })
        }
        // 运行时自带的编译器也算候选（有些包把 OLLVM 直接换成了默认 clang）。
        if let root = theosRoot {
            roots.append(Self.runtimeRoot(forTheos: root))
        }
        for root in roots {
            for binRel in ["usr/bin", "bin", "toolchain/bin", "usr/lib/llvm-16/bin"] {
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
        var dirs: [URL] = []
        for base in [root, Self.runtimeRoot(forTheos: root)] {
            for rel in ["sdks", "sdk", "toolchain/sdks"] {
                dirs.append(base.appendingPathComponent(rel, isDirectory: true))
            }
        }
        for dir in dirs {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { name in
                    var isDirectory: ObjCBool = false
                    return name.hasSuffix(".sdk")
                        && fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            if let sdk = names.first { return dir.appendingPathComponent(sdk).path }
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
