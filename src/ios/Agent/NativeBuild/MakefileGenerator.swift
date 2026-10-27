import Foundation

/// 工程里的 Makefile 从哪来。
///
/// 以前只有一个隐含前提：工程根目录必须有手写的 Theos `Makefile`，否则 `make` 直接
/// 报错退出，用户看到的只是一句「构建失败 / -1」。三种模式把这件事摊开：
enum NativeMakeMode: String, CaseIterable, Identifiable, Codable {
    /// 用工程自带的 Makefile（默认，行为与以前完全一致）。
    case project
    /// 没有 Makefile 就按源码自动生成一份，然后走原有 make 流程。
    case generate
    /// 完全不调用 make，直接按源码拼 clang 命令编一个可执行文件（实验性）。
    case direct

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .project: return "使用工程 Makefile"
        case .generate: return "自动生成 Makefile"
        case .direct: return "跳过 make 直接编译"
        }
    }

    var detail: String {
        switch self {
        case .project:
            return "要求工程根目录已有 Theos Makefile；没有就构不成，这也是以前「一构建就失败」最常见的原因。"
        case .generate:
            return "扫源码自动生成一份标准 Theos Makefile（tool / tweak / application 按源码类型判断），然后正常编译打包。已存在 Makefile 时不会覆盖。"
        case .direct:
            return "完全跳过 make，直接调 Theos 的 clang 编出一个可执行文件。适合单目标小工具；实验性，不处理打包。"
        }
    }
}

/// 扫描工程源码、生成 Theos Makefile、拼直接编译命令。
enum MakefileGenerator {

    static let sourceExtensions: Set<String> = [
        "m", "mm", "c", "cc", "cpp", "cxx", "swift", "x", "xm", "xi"
    ]

    private static let skippedDirectories: Set<String> = [
        ".git", ".theos", ".build", "packages", "obj", "sdks", "node_modules", "Caches"
    ]

    /// 工程内参与编译的源码（相对路径，已排序）。
    static func sources(in project: String) -> [String] {
        let root = URL(fileURLWithPath: project).standardizedFileURL
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                            includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if sourceExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url.path.replacingOccurrences(of: prefix, with: ""))
            }
        }
        return out.sorted()
    }

    /// 生成一份标准 Theos Makefile。没有源码时返回 nil。
    ///
    /// 类型判断刻意保守：有 `Tweak.x`/`.xm`/`.xi` 就当 tweak；否则有 `Info.plist`
    /// 就当 application；都不是就当 tool（命令行工具）。猜错时用户仍然可以手写
    /// Makefile 覆盖——`.generate` 模式永远不会覆盖已存在的文件。
    static func makefile(for project: String) -> String? {
        let files = sources(in: project)
        guard !files.isEmpty else { return nil }
        let fm = FileManager.default

        var name = URL(fileURLWithPath: project).lastPathComponent
        if let plist = NSDictionary(contentsOfFile: project + "/Info.plist"),
           let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty {
            name = executable
        }
        name = name.replacingOccurrences(of: " ", with: "_")
        if name.isEmpty { name = "MinisProject" }

        let hasTweakSources = files.contains { ["x", "xm", "xi"].contains(($0 as NSString).pathExtension.lowercased()) }
        let hasInfoPlist = fm.fileExists(atPath: project + "/Info.plist")

        let kind: String
        let nameVariable: String
        let includeTarget: String
        if hasTweakSources {
            kind = "tweak"; nameVariable = "TWEAK_NAME"; includeTarget = "tweak.mk"
        } else if hasInfoPlist {
            kind = "application"; nameVariable = "APPLICATION_NAME"; includeTarget = "application.mk"
        } else {
            kind = "tool"; nameVariable = "TOOL_NAME"; includeTarget = "tool.mk"
        }

        let needsARC = files.contains { ["m", "mm"].contains(($0 as NSString).pathExtension.lowercased()) }
        let filesLine = files.map { "\t\($0)" }.joined(separator: " \\\n")

        var lines: [String] = []
        lines.append("# 由 Minis 编译工作台自动生成（\(kind)）。原始文件缺失时不会覆盖已有 Makefile。")
        lines.append("ARCHS = arm64")
        lines.append("TARGET = iphone:clang:latest:latest")
        lines.append("")
        lines.append("include $(THEOS)/makefiles/common.mk")
        lines.append("")
        lines.append("\(nameVariable) = \(name)")
        lines.append("")
        lines.append("\(name)_FILES = \\")
        lines.append(filesLine)
        if needsARC { lines.append("\(name)_CFLAGS = -fobjc-arc") }
        if hasInfoPlist || kind == "application" { lines.append("\(name)_FRAMEWORKS = Foundation UIKit") } else { lines.append("\(name)_FRAMEWORKS = Foundation") }
        lines.append("")
        lines.append("include $(THEOS_MAKE_PATH)/\(includeTarget)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// `.direct` 模式：绕过 make，直接用 Theos 的 clang 编一个可执行文件。
    ///
    /// 找不到 SDK 时仍然给出命令（让用户看到到底缺什么），但会把警告打进日志。
    static func directCommand(for project: String, theosRoot: URL?) -> String? {
        let files = sources(in: project)
        guard !files.isEmpty else { return nil }
        let fm = FileManager.default

        var sdkPath = ""
        var clang = "clang"
        if let root = theosRoot {
            let sdks = root.appendingPathComponent("sdks", isDirectory: true)
            if let entries = try? fm.contentsOfDirectory(atPath: sdks.path) {
                let candidates = entries.filter { $0.hasSuffix(".sdk") }.sorted()
                if let newest = candidates.last {
                    sdkPath = sdks.appendingPathComponent(newest, isDirectory: true).path
                }
            }
            for relative in ["toolchain/usr/bin/clang", "usr/bin/clang"] {
                let candidate = root.appendingPathComponent(relative).path
                if fm.isExecutableFile(atPath: candidate) { clang = candidate; break }
            }
        }

        var name = URL(fileURLWithPath: project).lastPathComponent
        if name.isEmpty { name = "MinisTool" }

        var parts: [String] = ["echo '▸ 直接编译（跳过 make）…'"]
        if sdkPath.isEmpty {
            parts.append("echo '⚠︎ 没有找到 iPhoneOS SDK，clang 可能会失败；建议改用「自动生成 Makefile」模式'")
        }
        var args: [String] = [clang, "-arch", "arm64", "-O2", "-fmodules", "-fobjc-arc"]
        if !sdkPath.isEmpty { args.append("-isysroot"); args.append("\"\(sdkPath)\"") }
        args.append(contentsOf: files.map { "\"\($0)\"" })
        args.append("-framework"); args.append("Foundation")
        args.append("-o"); args.append("\"\(name)\"")
        parts.append("cd \"\(project)\" && " + args.joined(separator: " "))
        return parts.joined(separator: "\n")
    }
}
