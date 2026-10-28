//
//  RuntimeInstallSpec.swift
//  Minis — 运行时清单里的 install 块（自检 + 环境导出）
//
//  背景：schema 4 的每个 portable 运行时都用 `install` 描述「装完之后怎么算装好」：
//    * required_paths        必须存在的相对路径（完整性闸门）
//    * path_entries          要加到 PATH 前面的目录（通常是 bin）
//    * persistent_path_entries 跨版本保留的全局 CLI 前缀
//    * environment           运行时自己的环境变量，值里带 ${RUNTIME_ROOT}
//    * probe                 {executable, arguments, contains} 自检三元组
//    * sign_paths            装完需要签名的 Mach-O（不带权限的那组要单独处理）
//
//  以前这些字段被直接丢掉了，于是「装完 = 成功」，与清单的真实契约不一致：
//  半截解包、缺 devkit、path 没进 PATH 都会被当成装好。这里补上解码，并把
//  清单描述的环境原样翻译成子进程环境；theos 运行时额外派生 Node shim 读取的
//  CA_THEOS_* 变量，避免每个调用方各写一套。
//

import Foundation

/// `install.probe` —— 装完必须跑一次的自检命令。
struct RuntimeProbeSpec: Codable, Hashable {
    let executable: String
    let arguments: [String]
    let contains: String?

    enum CodingKeys: String, CodingKey {
        case executable, arguments, contains
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        contains = try container.decodeIfPresent(String.self, forKey: .contains)
    }
}

/// `install` 块。只对可解包的运行时（`portable-v1` 等）存在；`codex` / `theos`
/// 这类由 App 自己安装的 handler 没有这个字段，此时为 nil。
struct RuntimeInstallSpec: Codable, Hashable {
    let requiredPaths: [String]
    let pathEntries: [String]
    let persistentPathEntries: [String]
    let environment: [String: String]
    let probe: RuntimeProbeSpec?
    let signPaths: [String]
    let signPathsWithoutEntitlements: [String]

    enum CodingKeys: String, CodingKey {
        case requiredPaths = "required_paths"
        case pathEntries = "path_entries"
        case persistentPathEntries = "persistent_path_entries"
        case environment
        case probe
        case signPaths = "sign_paths"
        case signPathsWithoutEntitlements = "sign_paths_without_entitlements"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requiredPaths = try container.decodeIfPresent([String].self, forKey: .requiredPaths) ?? []
        pathEntries = try container.decodeIfPresent([String].self, forKey: .pathEntries) ?? ["usr/bin", "bin"]
        persistentPathEntries = try container.decodeIfPresent([String].self, forKey: .persistentPathEntries) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        probe = try container.decodeIfPresent(RuntimeProbeSpec.self, forKey: .probe)
        signPaths = try container.decodeIfPresent([String].self, forKey: .signPaths) ?? []
        signPathsWithoutEntitlements = try container.decodeIfPresent([String].self, forKey: .signPathsWithoutEntitlements) ?? []
        let paths = requiredPaths + pathEntries + persistentPathEntries + signPaths + signPathsWithoutEntitlements
            + (probe.map { [$0.executable] } ?? [])
        guard paths.allSatisfy(RuntimePathPolicy.isRelativePath),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
              probe?.arguments.allSatisfy({ !$0.contains("\0") }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unsafe runtime install path or environment"))
        }
    }

    /// 清单里没写 `install` 的运行时（App 自管 handler）按「无需自检」处理。
    static let none = RuntimeInstallSpec(requiredPaths: [],
                                         pathEntries: ["usr/bin", "bin"],
                                         persistentPathEntries: [],
                                         environment: [:],
                                         probe: nil,
                                         signPaths: [],
                                         signPathsWithoutEntitlements: [])

    private init(requiredPaths: [String], pathEntries: [String], persistentPathEntries: [String],
                 environment: [String: String], probe: RuntimeProbeSpec?,
                 signPaths: [String], signPathsWithoutEntitlements: [String]) {
        self.requiredPaths = requiredPaths
        self.pathEntries = pathEntries
        self.persistentPathEntries = persistentPathEntries
        self.environment = environment
        self.probe = probe
        self.signPaths = signPaths
        self.signPathsWithoutEntitlements = signPathsWithoutEntitlements
    }

    func expand(_ value: String, root: URL) -> String {
        value
            .replacingOccurrences(of: "${RUNTIME_ROOT}", with: root.path)
            .replacingOccurrences(of: "$RUNTIME_ROOT", with: root.path)
    }

    /// 运行时树自带的 `manifest.json` 里声明的 `sign_paths`。
    ///
    /// 中央清单不重复这些长名单（python 有 70 条：python3 + Python.framework +
    /// 68 个 extension framework；reverse_tools 9 条；theos 逐个 bin），
    /// 而是由每个 bundle 自己带一份。`install` 块缺失或不带 `sign_paths` 时
    /// 回退读它，否则「装了但一个都没签」—— 执行时就是 Bad executable。
    static func bundleSignPaths(in root: URL) -> [String] {
        guard let manifest = RuntimePathPolicy.containedURL("manifest.json", in: root),
              let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return (object["sign_paths"] as? [String]) ?? []
    }

    /// 该签名的目标：清单优先，其次 bundle 自带清单。
    func signTargets(in root: URL) -> (entitlements: [String], adhoc: [String]) {
        if !signPaths.isEmpty || !signPathsWithoutEntitlements.isEmpty {
            return (signPaths, signPathsWithoutEntitlements)
        }
        let manifest = RuntimePathPolicy.containedURL("manifest.json", in: root)
        let object = manifest.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (Self.bundleSignPaths(in: root),
                object?["sign_paths_without_entitlements"] as? [String] ?? [])
    }

    /// `required_paths` 里当前缺失的项（顺序与清单一致）。
    func missingPaths(in root: URL) -> [String] {
        let fm = FileManager.default
        return requiredPaths.filter {
            guard let url = RuntimePathPolicy.containedURL($0, in: root) else { return true }
            return !fm.fileExists(atPath: url.path)
        }
    }
}

/// Shared containment policy for manifest paths, signing targets and tar members.
/// Lexical checks alone do not stop an in-tree symlink chain from escaping.
enum RuntimePathPolicy {
    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains("..")
    }

    static func containedURL(_ path: String, in root: URL) -> URL? {
        guard isRelativePath(path) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().path
        guard resolved == base.path || resolved.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

// MARK: - 环境导出

/// 把 `install` 块翻译成子进程能用的环境。
///
/// 变量集合刻意与运行时端保持一致，因为 Node 运行时的 `lib/codex/*.js` 就是读这些：
/// `CA_TOOL_<ID>_RUNTIME_ROOT`（runtimeRoot）、`SHELL` / `CA_THEOS_BASH`
/// （preferredShell）、`CA_THEOS_SDKROOT` + `CA_THEOS_CLANG/CLANGXX/MAKE`（编译默认值）。
enum RuntimeEnvironmentOverlay {

    struct Result: Equatable {
        var exports: [String: String]
        var pathEntries: [String]

        var pathPrefix: String? {
            pathEntries.isEmpty ? nil : pathEntries.joined(separator: ":")
        }
    }

    static func build(descriptor: RuntimeDescriptor, root: URL) -> Result {
        let spec = descriptor.installSpecOrNone
        var exports: [String: String] = [:]

        // 1. 清单声明的环境，${RUNTIME_ROOT} 展开成真实安装根。
        for (key, value) in spec.environment {
            exports[key] = spec.expand(value, root: root)
        }

        // 2. 运行时标识，供脚本判断「自己在哪个运行时里」。
        exports["CA_RUNTIME_ID"] = descriptor.id
        exports["CA_RUNTIME_VERSION"] = descriptor.version
        exports["CA_RUNTIME_HANDLER"] = descriptor.handler ?? "portable-v1"
        exports["CA_RUNTIME_ROOT"] = root.path
        exports["CA_TOOL_\(envelopeKey(descriptor.id))_RUNTIME_ROOT"] = root.path
        // 兼容既有调用方（设置页与 NativeToolchain 之前用的是这个名字）。
        exports["MINIS_RUNTIME_ROOT"] = root.path

        // 3. PATH：清单声明的 path_entries 优先，然后是运行时自身的 bin/usr/bin，
        //    最后才是系统目录，保证运行时的 git/rg/clang 先被找到。
        var search: [String] = []
        let fm = FileManager.default
        for entry in spec.pathEntries {
            guard let url = RuntimePathPolicy.containedURL(entry, in: root),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if !search.contains(url.path) { search.append(url.path) }
        }

        // Published persistent entries are home-relative, not runtime-relative.
        // Do not rename the CodexApp component: it is part of the Node asset contract.
        let home = fm.homeDirectoryForCurrentUser
        for entry in spec.persistentPathEntries {
            guard let url = RuntimePathPolicy.containedURL(entry, in: home),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if !search.contains(url.path) { search.append(url.path) }
        }

        // Staged Theos tools link against sibling dylibs before they are installed.
        for (key, paths) in [("DYLD_LIBRARY_PATH", ["usr/lib", "lib"]),
                             ("DYLD_FRAMEWORK_PATH", ["Frameworks"])] {
            let directories = paths.compactMap { RuntimePathPolicy.containedURL($0, in: root) }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            if exports[key] == nil, !directories.isEmpty {
                exports[key] = directories.map(\.path).joined(separator: ":")
            }
        }

        // 4. theos 运行时：派生 CA_THEOS_*（清单不声明，靠树结构推导）。
        if descriptor.handler == "theos" {
            exports.merge(theosExports(root: root, search: search)) { current, _ in current }
        }

        return Result(exports: exports, pathEntries: search)
    }

    /// `CA_TOOL_<ID>_RUNTIME_ROOT` 的键名规则与运行时端一致：大写下划线。
    static func envelopeKey(_ id: String) -> String {
        id.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    /// Theos 树的 `sdks/` 与 `toolchain/**/bin/clang` 位置在两代归档里都不同，
    /// 因此按目录扫描而不是硬编码路径。
    static func theosExports(root: URL, search: [String]) -> [String: String] {
        let fm = FileManager.default
        var exports: [String: String] = [:]
        // theos 归档把 checkout 放在 `theos/`，老布局直接铺在根上。
        let candidates = [root.appendingPathComponent("theos", isDirectory: true), root]
        if let theos = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("makefiles").path) })
            ?? candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            exports["THEOS"] = theos.path
            let sdks = theos.appendingPathComponent("sdks", isDirectory: true)
            if let sdk = latestSDK(in: sdks) {
                exports["THEOS_SDKROOT"] = sdks.path
                exports["CA_THEOS_SDKROOT"] = sdk.path
            }
            for (name, key) in [("clang", "CA_THEOS_CLANG"), ("clang++", "CA_THEOS_CLANGXX")] {
                if let binary = firstExecutable(named: name, under: theos, depth: 4),
                   exports[key] == nil {
                    exports[key] = binary.path
                }
            }
        }
        for (name, key) in [("make", "CA_THEOS_MAKE"), ("bash", "CA_THEOS_BASH")] {
            for directory in search {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate.path) {
                    exports[key] = candidate.path
                    break
                }
            }
        }
        return exports
    }

    private static func latestSDK(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil) else { return nil }
        return entries
            .filter { $0.pathExtension == "sdk" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            .last
    }

    /// 在 `root` 下最多 `depth` 层找可执行文件（toolchain 布局有两三代差异）。
    private static func firstExecutable(named name: String, under root: URL, depth: Int) -> URL? {
        let fm = FileManager.default
        guard depth >= 0,
              let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isExecutableKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen > 20000 { break }
            let relativeDepth = url.pathComponents.count - root.pathComponents.count
            if relativeDepth > depth { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == name, fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
