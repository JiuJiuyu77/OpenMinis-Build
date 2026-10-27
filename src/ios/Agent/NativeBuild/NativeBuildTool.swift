//
//  NativeBuildTool.swift
//  Minis — native_build 工具（Agent 直接调原生工具链）
//
//  与 shell_execute 的区别：这条路径不经过 iSH（不模拟 Linux），
//  直接把命令交给 App 进程内的真实 iOS 工具链执行，产物是设备上的 .deb。
//

import Foundation

enum NativeBuildTool {

    static let name = "native_build"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: """
            Build an iOS tweak project with the on-device NATIVE toolchain (Theos: clang/ld64/dpkg-deb), \
            without the iSH Linux sandbox. Use this instead of shell_execute when the user wants to compile \
            a Theos project into a .deb: it runs `make package` on the device filesystem and returns the \
            produced .deb paths plus the build log. Paths are real device paths (e.g. \
            /var/mobile/Documents/MyTweak), not iSH paths (/var/minis/...).
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string,
                                             description: "A concise 5-10 word summary of what this tool call does, in the user's language (e.g. '编译 MyTweak 为 deb')."),
                "path": AgentToolParam(type: .string,
                                       description: "Absolute device path of the project directory (must contain a Theos Makefile)."),
                "scheme": AgentToolParam(type: .string,
                                         description: "Packaging scheme: rootless (default), rootful, or roothide.",
                                         enumValues: ["rootless", "rootful", "roothide"]),
                "archs": AgentToolParam(type: .string,
                                        description: "Target architectures, default arm64. Use 'arm64 arm64e' for both."),
                "clean": AgentToolParam(type: .boolean,
                                        description: "Run `make clean` before packaging. Default false."),
                "extra": AgentToolParam(type: .string,
                                        description: "Extra make arguments appended verbatim, e.g. 'DEBUG=0'."),
                "make_mode": AgentToolParam(type: .string,
                                            description: "How to handle the build file: project (use the Makefile in the project, default), generate (auto-generate a Theos Makefile from sources when missing, then build), direct (skip make entirely and compile with clang; experimental).",
                                            enumValues: ["project", "generate", "direct"]),
                "profile": AgentToolParam(type: .string,
                                          description: "Name of a saved build profile (device UI: 编译工作台 → 编译配置). Its scheme/archs/obfuscation/protection/output become defaults; arguments you pass explicitly still win."),
                "obfuscation": AgentToolParam(type: .string,
                                              description: "OLLVM obfuscation strength: off (default), light, balanced, strong, paranoid, extreme. Requires the OLLVM runtime to be installed. extreme adds indirect-branch/indirect-call passes and a much larger binary.",
                                              enumValues: BuildObfuscation.allCases.map(\.rawValue)),
                "cflags": AgentToolParam(type: .string,
                                         description: "Extra C/ObjC compiler flags appended verbatim."),
                "ldflags": AgentToolParam(type: .string,
                                          description: "Extra linker flags appended verbatim."),
                "jobs": AgentToolParam(type: .integer,
                                       description: "Parallel make jobs (default 4)."),
                "product": AgentToolParam(type: .string,
                                          description: "What to produce: deb (default), dylib, or ipaShell (inject the built dylib into an .ipa you provide).",
                                          enumValues: BuildProductKind.allCases.map(\.rawValue)),
                "incremental": AgentToolParam(type: .boolean,
                                              description: "Reuse previous objects instead of a clean build (default true)."),
                "strip_symbols": AgentToolParam(type: .boolean,
                                                description: "Run `strip -x` on the produced dylib (default false)."),
                "hide_symbols": AgentToolParam(type: .boolean,
                                               description: "Compile with -fvisibility=hidden (default false)."),
                "encrypt_strings": AgentToolParam(type: .boolean,
                                                  description: "Enable OLLVM string encryption (-mllvm -sobf). Requires the OLLVM runtime."),
                "shell_ipa": AgentToolParam(type: .string,
                                            description: "Absolute path of the .ipa to inject into when product=ipaShell."),
                "timeout": AgentToolParam(type: .integer,
                                          description: "Timeout in seconds (default 1800)."),
                "tool_note": AgentToolParam(type: .string,
                                            description: "Optional one-line note shown to the user."),
            ],
            required: ["tool_title", "path"],
            propertyOrdering: ["tool_title", "path", "scheme", "archs", "clean", "extra",
                               "obfuscation", "cflags", "ldflags", "jobs", "timeout",
                               "product", "incremental", "strip_symbols", "hide_symbols",
                               "encrypt_strings", "shell_ipa", "tool_note"]
        )
    }

    /// 供 AIChatViewModel+ConcurrentTools 的分发分支调用。
    static func perform(args: [String: Any]) async -> (text: String, ok: Bool) {
        // [T-profile-to-model] 编译配置档也要暴露给模型：profile 只提供**默认值**，
        // 模型显式传的参数优先级更高。否则用户在界面上配好的混淆/输出，模型每次
        // 调 native_build 都得重新猜。
        var args = args
        if let raw = (args["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let saved: BuildProfile? = await MainActor.run {
                BuildProfileStore.shared.profiles.first { $0.name == raw }
            }
            if let saved {
                if args["scheme"] == nil { args["scheme"] = saved.scheme }
                if args["archs"] == nil { args["archs"] = saved.archs }
                if args["obfuscation"] == nil { args["obfuscation"] = saved.obfuscation.rawValue }
                if args["clean"] == nil { args["clean"] = saved.cleanBeforeBuild }
                if args["incremental"] == nil { args["incremental"] = saved.incremental }
                if args["jobs"] == nil { args["jobs"] = saved.jobs }
                if args["extra"] == nil && !saved.extraFlags.isEmpty { args["extra"] = saved.extraFlags }
                if args["strip_symbols"] == nil { args["strip_symbols"] = saved.stripSymbols }
                if args["hide_symbols"] == nil { args["hide_symbols"] = saved.hideSymbols }
                if args["encrypt_strings"] == nil { args["encrypt_strings"] = saved.encryptStrings }
                if args["make_mode"] == nil { args["make_mode"] = saved.makeMode.rawValue }
            }
        }

        var path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // [T-native-build-path] 原生工具链在本进程里 spawn 真实的 clang/ld64/make，
        // 访问的是**设备真实文件系统**；iSH 沙盒里的 /var/minis/... 在设备侧不可见
        // （实测：/、/private/var/mobile/Documents、Theos 目录都能认，唯独沙盒路径认不到）。
        // 这里先尝试把沙盒路径映射成设备路径；映射不到就给一条能照做的指令，
        // 而不是让调用方只看到一句 "project directory not found"。
        if path.hasPrefix("/var/minis") {
            if let mapped = Self.mapSandboxPathToDevice(path) {
                path = mapped
            } else {
                return ("""
                Error: `\(path)` 是 iSH 沙盒路径，原生工具链看不到它。

                原生编译走的是设备真实文件系统（posix_spawn 真实的 clang/ld64/make），
                而 /var/minis/... 属于 iSH 的 Linux 根文件系统，设备侧没有这个路径。

                请把工程放到设备侧目录，例如：
                  /var/mobile/Documents/<项目名>

                需要的话可以先用 shell_execute 复制过去：
                  cp -a <沙盒内工程路径> /var/mobile/Documents/
                然后 native_build 传 path=/var/mobile/Documents/<项目名>。
                """, false)
            }
        }

        var isDir: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ("Error: project directory not found at \(path.isEmpty ? "(empty)" : path)", false)
        }

        let toolchain = NativeToolchain.shared
        guard toolchain.isAvailable else {
            return ("""
            Error: native toolchain unavailable.
            No usable Theos runtime / shell was found. Install it from Settings → Developer Runtime, \
            or point Settings → Executor → Toolchain diagnostics at an existing Theos root.
            In a sandboxed install the native runtime cannot run at all — commands stay in iSH; \
            Settings → Runtime diagnostics → One-tap repair switches the executor and explains why.
            Runtime roots searched:
            \(NativeToolchain.candidateRoots().prefix(8).map { "  " + $0.path }.joined(separator: "\n"))
            Fix without a rebuild: Settings → Executor → Toolchain diagnostics → set the Theos root manually.
            """, false)
        }

        let scheme = (args["scheme"] as? String) ?? "rootless"
        let archs = (args["archs"] as? String) ?? "arm64"
        let clean = (args["clean"] as? Bool) ?? false
        let extra = (args["extra"] as? String) ?? ""
        let timeout = TimeInterval((args["timeout"] as? Int) ?? 1800)

        let obfuscation = BuildObfuscation.parse(args["obfuscation"] as? String)
        let cflags = (args["cflags"] as? String) ?? ""
        let ldflags = (args["ldflags"] as? String) ?? ""
        let jobs = (args["jobs"] as? Int) ?? 4

        if obfuscation.requiresOLLVM {
            // 没有 OLLVM 时强开会得到一堆 `unknown argument -mllvm`，比直接
            // 拒绝更难查。这里提前说明，并让用户知道怎么继续。
            let hasOLLVM = await MainActor.run { RuntimeCapabilityNames.ollvmInstalled }
            if !hasOLLVM {
                return ("""
                Error: obfuscation is set to \(obfuscation.rawValue) but the OLLVM runtime is not installed.
                Install it from Settings → Developer Runtime (OLLVM), or pass obfuscation=off.
                """, false)
            }
        }

        let product = BuildProductKind(rawValue: (args["product"] as? String) ?? "") ?? .deb
        let incremental = (args["incremental"] as? Bool) ?? true
        let protection = BuildProtection(
            stripSymbols: (args["strip_symbols"] as? Bool) ?? false,
            hideSymbols: (args["hide_symbols"] as? Bool) ?? false,
            encryptStrings: (args["encrypt_strings"] as? Bool) ?? false)
        let shellIPA = (args["shell_ipa"] as? String) ?? ""

        if protection.encryptStrings {
            let hasOLLVM = await MainActor.run { RuntimeCapabilityNames.ollvmInstalled }
            if !hasOLLVM {
                return ("""
                Error: encrypt_strings needs the OLLVM runtime (-mllvm -sobf).
                Install it from Settings → Developer Runtime (OLLVM), or drop the flag.
                """, false)
            }
        }
        if product == .ipaShell && shellIPA.isEmpty {
            return ("Error: product=ipaShell needs shell_ipa (absolute path of the .ipa to inject into).", false)
        }

        let makeMode = NativeMakeMode(rawValue: (args["make_mode"] as? String) ?? "project") ?? .project
        let config = NativeBuildConfig(projectPath: path,
                                       scheme: scheme,
                                       archs: archs,
                                       cleanBeforeBuild: clean,
                                       extraFlags: extra,
                                       timeout: timeout,
                                       obfuscation: obfuscation,
                                       cflags: cflags,
                                       ldflags: ldflags,
                                       jobs: jobs,
                                       product: product,
                                       incremental: incremental,
                                       protection: protection,
                                       shellSourceIPA: shellIPA,
                                       makeMode: makeMode,
                                       generatedMakefile: makeMode == .generate
                                           ? MakefileGenerator.makefile(for: path) : nil,
                                       directCommand: makeMode == .direct
                                           ? MakefileGenerator.directCommand(for: path,
                                                                             theosRoot: NativeToolchain.shared.theosRoot)
                                           : nil)

        let result = await NativeBuildService.runBuild(config)

        var lines: [String] = []
        lines.append(result.ok ? "✓ \(result.message)" : "✗ \(result.message)")
        lines.append("工程：\(path)（\(toolchain.detectKind(path).rawValue)）")
        lines.append("命令：\(config.command.replacingOccurrences(of: "\n", with: " ; "))")
        lines.append("用时：\(String(format: "%.1f", result.seconds)) 秒，退出码 \(result.exitCode)")
        if result.artifacts.isEmpty {
            lines.append("产物：无")
        } else {
            lines.append("产物：")
            for artifact in result.artifacts {
                let attrs = try? FileManager.default.attributesOfItem(atPath: artifact)
                let size = (attrs?[.size] as? Int64) ?? 0
                lines.append("  \(artifact)  (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
            }
        }
        lines.append("")
        lines.append("--- 构建日志（尾部 4000 字）---")
        lines.append(String(result.log.suffix(4000)))
        return (lines.joined(separator: "\n"), result.ok)
    }

    /// 把 iSH 沙盒路径映射到设备侧真实路径。命中不了就返回 nil，由调用方给指令。
    /// 只做若干候选前缀的存在性判断——猜错不会有副作用，猜中就直接能用。
    static func mapSandboxPathToDevice(_ path: String) -> String? {
        let home = NSHomeDirectory()
        guard path.hasPrefix("/var/minis") else { return nil }
        let rel = path.replacingOccurrences(of: "/var/minis/", with: "")
        let candidates = [
            "\(home)/Documents/\(rel)",
            "\(home)/Documents/alpine-rootfs/data/var/minis/\(rel)",
            "\(home)/Library/Application Support/minis/\(rel)",
            "/var/mobile/Documents/\(rel)"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
