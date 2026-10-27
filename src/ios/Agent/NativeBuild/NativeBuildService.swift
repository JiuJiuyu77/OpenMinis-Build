//
//  NativeBuildService.swift
//  Minis — 编译服务：工程 → make package → .deb
//
//  同时服务两个消费者：
//   · BuildWorkbenchView（可视化界面）
//   · native_build 工具（Agent 直接调用）
//

import Foundation

/// 构建产物类型。
enum BuildProductKind: String, CaseIterable, Identifiable {
    /// 标准 Theos 打包：`make package` → .deb
    case deb
    /// 只编译 dylib，不做 deb 打包（工程里 `TWEAK_NAME` / 库 target）
    case dylib
    /// 打壳：把已有 App 解包 → 注入 dylib → 重打包成 .ipa/.tipa
    case ipaShell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deb: return AppLocalized("Debian package (.deb)")
        case .dylib: return AppLocalized("Dynamic library (.dylib)")
        case .ipaShell: return AppLocalized("App shell (.ipa with injected dylib)")
        }
    }

    var explanation: String {
        switch self {
        case .deb:
            return AppLocalized("Runs `make package` and returns the .deb Theos produces.")
        case .dylib:
            return AppLocalized("Runs the build target and returns the .dylib without packaging a .deb.")
        case .ipaShell:
            return AppLocalized("Takes an .ipa you provide, injects the built .dylib into its main executable and repackages it.")
        }
    }
}

struct NativeBuildConfig {
    var projectPath: String
    var scheme: String = "rootless"     // rootless / rootful / roothide
    var archs: String = "arm64"
    var cleanBeforeBuild: Bool = false
    var extraFlags: String = ""
    var target: String = ""             // 例：iphone:clang:latest:15.0
    var timeout: TimeInterval = 1800
    /// 混淆强度（OLLVM）。`.off` 时不注入任何 -mllvm 参数。
    var obfuscation: BuildObfuscation = .off
    /// 追加到 CFLAGS/CXXFLAGS 的自定义参数（可视化里的“自定义编译参数”）。
    var cflags: String = ""
    /// 追加到 LDFLAGS 的自定义参数。
    var ldflags: String = ""
    /// 编译并行度；<=0 时用 4。
    var jobs: Int = 4
    /// 只打包、不重新编译（`make package FINALPACKAGE=1` 会增量，这个开关保留
    /// 给“产物已经编好、只需要重打包”的场景）。
    var packageOnly: Bool = false
    /// 产物类型：deb / dylib / 打壳 ipa。
    var product: BuildProductKind = .deb
    /// 增量编译：不清 `make clean`，复用 `.theos` 中间产物。
    /// （Theos 本身增量；这个开关只决定要不要先 clean。）
    var incremental: Bool = true
    /// 符号剥离 / 隐藏符号 / 字符串加密。
    var protection: BuildProtection = BuildProtection()
    /// 打壳用的输入 ipa（`product == .ipaShell` 时必填）。
    var shellSourceIPA: String = ""
    /// 打壳注入的 dylib 名（默认用工程编出来的那个）。
    var shellDylibName: String = ""
    /// 没有 Makefile 时怎么办。默认 `.project`，与旧行为一致。
    var makeMode: NativeMakeMode = .project
    /// `.generate` 模式预生成的 Makefile 内容（service 构造配置时扫源码填入）。
    var generatedMakefile: String? = nil
    /// `.direct` 模式预拼好的 clang 命令（跳过 make）。
    var directCommand: String? = nil

    /// 实际要执行的 make 目标。
    var makeGoal: String {
        switch product {
        case .deb, .ipaShell: return "package"
        case .dylib: return "all"
        }
    }

    /// 打壳前是否必须编出 dylib。
    var needsCompile: Bool { !packageOnly }

    /// 拼进 make 命令行的一组变量。保持 key=value 形式，避免依赖 shell 引号。
    var makeVariables: [String] {
        var parts: [String] = []
        if scheme != "rootful" { parts.append("THEOS_PACKAGE_SCHEME=\(scheme)") }
        parts.append("FINALPACKAGE=1")
        // Theos is incremental by default: it only rebuilds what changed and its
        // objects live in `.theos/`. There is no `THEOS_BUILD_INCREMENTAL`
        // variable to set, so "incremental" means exactly one thing here — do
        // NOT run `make clean`. Passing a made-up variable would be a lie that
        // also silently overrides nothing.
        _ = incremental
        if !archs.isEmpty { parts.append("ARCHS=\(archs)") }
        if !target.isEmpty { parts.append("TARGET=\(target)") }

        // 混淆 + 自定义 CFLAGS 合并成一个变量：命令行上不支持 `VAR+=x`
        // （那是 makefile 内部语法），两个 `VAR=` 只会后者覆盖前者。
        var allCFlags: [String] = []
        if obfuscation.requiresOLLVM {
            allCFlags.append(obfuscation.compilerFlags.joined(separator: " "))
        }
        let protectionFlags = protection.compilerFlags.joined(separator: " ")
        if !protectionFlags.isEmpty { allCFlags.append(protectionFlags) }
        if !cflags.isEmpty { allCFlags.append(cflags) }
        if !allCFlags.isEmpty {
            let merged = allCFlags.joined(separator: " ")
            // 整体加引号，否则 make 会把每个 -mllvm flag 当成独立变量。
            parts.append("ADDITIONAL_CFLAGS=\"\(merged)\"")
            parts.append("ADDITIONAL_OBJCFLAGS=\"\(merged)\"")
            parts.append("ADDITIONAL_CPPFLAGS=\"\(merged)\"")
        }
        if !ldflags.isEmpty { parts.append("ADDITIONAL_LDFLAGS=\"\(ldflags)\"") }
        if !extraFlags.isEmpty { parts.append(extraFlags) }
        return parts
    }

    var command: String {
        // `.direct`：完全绕过 make。
        if let directCommand, !directCommand.isEmpty { return directCommand }

        let jobCount = jobs > 0 ? jobs : 4
        var cmd = (["make -j\(jobCount) \(makeGoal)"] + makeVariables).joined(separator: " ")

        // `.generate`：工程里没有 Makefile 时，先把它写出来再编译。
        // 用 `[ ! -f Makefile ]` 保护，绝不覆盖用户手写的 Makefile。
        if let generatedMakefile, !generatedMakefile.isEmpty {
            let eof = "MINIS_GENERATED_MAKEFILE"
            cmd = "if [ ! -f Makefile ]; then\n"
                + "  echo '▸ 工程没有 Makefile，正在按源码自动生成…'\n"
                + "  cat > Makefile <<'" + eof + "'\n" + generatedMakefile + "\n" + eof + "\n"
                + "else\n  echo '▸ 使用工程已有的 Makefile'\nfi\n"
                + cmd
        }
        // 「构建前清理」勾了，或者用户关掉了增量编译，都要先 clean。
        if cleanBeforeBuild || !incremental {
            cmd = "echo '▸ 清理旧产物…'\nmake clean >/dev/null 2>&1 || true\n" + cmd
        }
        if protection.stripSymbols {
            // Strip only AFTER the link completes; `-x` drops local symbols and
            // keeps the dynamic symbol table so the dylib still loads. `find
            // -name` takes ONE pattern, so two invocations rather than a glob
            // list that would silently match nothing.
            cmd += "\necho '▸ 剥离符号…'"
                + "\nfind . -name '*.dylib' -type f -exec strip -x {} \\; 2>/dev/null || true"
        }
        return cmd
    }
}

struct NativeBuildResult {
    var ok: Bool
    var exitCode: Int32
    var seconds: Double
    var artifacts: [String]
    var log: String
    var message: String
}

@MainActor
final class NativeBuildService: ObservableObject {

    static let shared = NativeBuildService()

    @Published var projectPath: String
    @Published var scheme: String
    @Published var archs: String
    @Published var cleanBeforeBuild: Bool
    @Published var extraFlags: String
    @Published var obfuscation: BuildObfuscation
    @Published var cflags: String
    @Published var ldflags: String
    @Published var jobs: Int
    /// 没有 Makefile 时怎么办（`.project` / `.generate` / `.direct`）。
    @Published var makeMode: NativeMakeMode = .project
    @Published var packageOnly: Bool
    @Published var product: BuildProductKind
    @Published var incremental: Bool
    @Published var stripSymbols: Bool
    @Published var hideSymbols: Bool
    @Published var encryptStrings: Bool
    @Published var shellSourceIPA: String
    @Published var running = false
    @Published var logLines: [String] = []
    @Published var lastResult: NativeBuildResult?
    @Published private(set) var currentPID: pid_t = 0

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let project = "nativeBuild.project"
        static let scheme = "nativeBuild.scheme"
        static let archs = "nativeBuild.archs"
        static let clean = "nativeBuild.clean"
        static let extra = "nativeBuild.extra"
        static let obfuscation = "nativeBuild.obfuscation"
        static let cflags = "nativeBuild.cflags"
        static let ldflags = "nativeBuild.ldflags"
        static let jobs = "nativeBuild.jobs"
        static let packageOnly = "nativeBuild.packageOnly"
        static let product = "nativeBuild.product"
        static let incremental = "nativeBuild.incremental"
        static let stripSymbols = "nativeBuild.stripSymbols"
        static let hideSymbols = "nativeBuild.hideSymbols"
        static let encryptStrings = "nativeBuild.encryptStrings"
        static let shellSourceIPA = "nativeBuild.shellSourceIPA"
    }

    init() {
        projectPath = defaults.string(forKey: Keys.project) ?? ""
        scheme = defaults.string(forKey: Keys.scheme) ?? "rootless"
        archs = defaults.string(forKey: Keys.archs) ?? "arm64"
        cleanBeforeBuild = defaults.bool(forKey: Keys.clean)
        extraFlags = defaults.string(forKey: Keys.extra) ?? ""
        obfuscation = BuildObfuscation.parse(defaults.string(forKey: Keys.obfuscation))
        cflags = defaults.string(forKey: Keys.cflags) ?? ""
        ldflags = defaults.string(forKey: Keys.ldflags) ?? ""
        let storedJobs = defaults.integer(forKey: Keys.jobs)
        jobs = storedJobs > 0 ? storedJobs : 4
        packageOnly = defaults.bool(forKey: Keys.packageOnly)
        product = BuildProductKind(rawValue: defaults.string(forKey: Keys.product) ?? "") ?? .deb
        // 默认开启增量：首次编译仍旧是全量，之后的重复构建省掉大量时间。
        incremental = defaults.object(forKey: Keys.incremental) == nil
            ? true : defaults.bool(forKey: Keys.incremental)
        stripSymbols = defaults.bool(forKey: Keys.stripSymbols)
        hideSymbols = defaults.bool(forKey: Keys.hideSymbols)
        encryptStrings = defaults.bool(forKey: Keys.encryptStrings)
        shellSourceIPA = defaults.string(forKey: Keys.shellSourceIPA) ?? ""
    }

    func persist() {
        defaults.set(projectPath, forKey: Keys.project)
        defaults.set(scheme, forKey: Keys.scheme)
        defaults.set(archs, forKey: Keys.archs)
        defaults.set(cleanBeforeBuild, forKey: Keys.clean)
        defaults.set(extraFlags, forKey: Keys.extra)
        defaults.set(obfuscation.rawValue, forKey: Keys.obfuscation)
        defaults.set(cflags, forKey: Keys.cflags)
        defaults.set(ldflags, forKey: Keys.ldflags)
        defaults.set(jobs, forKey: Keys.jobs)
        defaults.set(packageOnly, forKey: Keys.packageOnly)
        defaults.set(product.rawValue, forKey: Keys.product)
        defaults.set(incremental, forKey: Keys.incremental)
        defaults.set(stripSymbols, forKey: Keys.stripSymbols)
        defaults.set(hideSymbols, forKey: Keys.hideSymbols)
        defaults.set(encryptStrings, forKey: Keys.encryptStrings)
        defaults.set(shellSourceIPA, forKey: Keys.shellSourceIPA)
    }

    /// 当前的保护选项快照。
    var protection: BuildProtection {
        BuildProtection(stripSymbols: stripSymbols,
                        hideSymbols: hideSymbols,
                        encryptStrings: encryptStrings)
    }

    /// 组装一份配置（UI 与工具共用同一套字段顺序）。
    func makeConfig() -> NativeBuildConfig {
        NativeBuildConfig(projectPath: projectPath,
                          scheme: scheme,
                          archs: archs,
                          cleanBeforeBuild: cleanBeforeBuild,
                          extraFlags: extraFlags,
                          obfuscation: obfuscation,
                          cflags: cflags,
                          ldflags: ldflags,
                          jobs: jobs,
                          packageOnly: packageOnly,
                          product: product,
                          incremental: incremental,
                          protection: protection,
                          shellSourceIPA: shellSourceIPA,
                          makeMode: makeMode,
                          generatedMakefile: makeMode == .generate
                              ? MakefileGenerator.makefile(for: projectPath) : nil,
                          directCommand: makeMode == .direct
                              ? MakefileGenerator.directCommand(for: projectPath,
                                                                theosRoot: NativeToolchain.shared.theosRoot)
                              : nil)
    }

    var toolchainReady: Bool { NativeToolchain.shared.isAvailable }

    var artifacts: [String] {
        guard !projectPath.isEmpty else { return [] }
        return NativeToolchain.shared.artifacts(in: projectPath)
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 4000 { logLines.removeFirst(logLines.count - 4000) }
    }

    /// 供 UI 调用：后台跑，状态回主线程。
    func startBuild() {
        guard !running else { return }
        guard !projectPath.isEmpty else {
            appendLog("✗ 请先选择工程目录")
            return
        }
        guard toolchainReady else {
            let roots = NativeToolchain.candidateRoots().prefix(4).map(\.path).joined(separator: "\n  ")
            appendLog("""
            ✗ 未找到原生工具链（缺 Theos 或可用 shell）。
            已搜索：
              \(roots)
            下一步：在下方「工具链诊断」里手动指定 Theos 根目录，或到 设置 → Developer Runtime 安装 Theos。
            """)
            return
        }
        running = true
        logLines.removeAll()
        persist()

        let config = makeConfig()
        Task { @MainActor in
            let result = await NativeBuildService.runBuild(config) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            } onSpawn: { [weak self] pid in
                Task { @MainActor in self?.currentPID = pid }
            }
            self.running = false
            self.currentPID = 0
            var final = result
            // 打壳：编译成功后再把 dylib 注入用户提供的 ipa。
            if result.ok, config.product == .ipaShell {
                final = await self.packShell(config: config, build: result)
            }
            self.lastResult = final
            self.appendLog(final.ok ? "✓ 构建成功 · \(String(format: "%.1f", final.seconds)) 秒"
                                    : "✗ 构建失败（退出码 \(final.exitCode)）")
            for artifact in final.artifacts { self.appendLog("产物：\(artifact)") }
        }
    }

    /// 打壳阶段：把刚编出来的 dylib 注入 `shellSourceIPA`。
    private func packShell(config: NativeBuildConfig, build: NativeBuildResult) async -> NativeBuildResult {
        guard !config.shellSourceIPA.isEmpty else {
            appendLog("✗ 打壳需要先在「打壳」里选择输入的 .ipa")
            return NativeBuildResult(ok: false, exitCode: -1, seconds: build.seconds,
                                     artifacts: build.artifacts, log: build.log,
                                     message: "打壳：未选择输入 ipa")
        }
        guard let dylib = IPAShellPacker.findBuiltDylib(in: config.projectPath) else {
            appendLog("✗ 没找到编出来的 .dylib，无法打壳")
            return NativeBuildResult(ok: false, exitCode: -1, seconds: build.seconds,
                                     artifacts: build.artifacts, log: build.log,
                                     message: "打壳：未找到 .dylib 产物")
        }
        let source = URL(fileURLWithPath: config.shellSourceIPA)
        let stem = source.deletingPathExtension().lastPathComponent
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-shelled.ipa")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-ipashell-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        appendLog("▸ 打壳：\(dylib.lastPathComponent) → \(source.lastPathComponent)")
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try IPAShellPacker.pack(sourceIPA: source, dylib: dylib, output: output,
                                       workDirectory: work) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
            }.value
            appendLog("✓ 打壳完成：\(outcome.ipa.path)")
            appendLog("⚠️ 注入后原签名失效：安装前请用 ldid -S<entitlements> 重签（TrollStore 会代签）。")
            return NativeBuildResult(ok: true, exitCode: 0, seconds: build.seconds,
                                     artifacts: [outcome.ipa.path], log: build.log,
                                     message: "打壳成功（需要重签）")
        } catch {
            appendLog("✗ 打壳失败：\(error.localizedDescription)")
            return NativeBuildResult(ok: false, exitCode: -1, seconds: build.seconds,
                                     artifacts: build.artifacts, log: build.log,
                                     message: "打壳失败：\(error.localizedDescription)")
        }
    }

    func cancel() {
        let pid = currentPID
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        appendLog("… 已发送终止信号")
    }

    func refreshToolchain() {
        NativeToolchain.shared.resetCache()
    }

    /// 核心：执行一次构建（纯函数式，UI 与工具共用）。
    nonisolated static func runBuild(_ config: NativeBuildConfig,
                                     onLine: ((String) -> Void)? = nil,
                                     onSpawn: ((pid_t) -> Void)? = nil) async -> NativeBuildResult {
        let toolchain = NativeToolchain.shared
        guard toolchain.isAvailable else {
            // [T-build-exit-minus1] 以前这里返回 log: ""，工具结果只剩「退出码 -1」，
            // 完全看不出是没装运行时、路径不对，还是只缺一个 shell。把逐项诊断塞进日志。
            let diag = toolchain.diagnostics()
            let diagLog = (["原生工具链不可用：逐项诊断",
                            diag.suggestedRoot.map { "建议根目录：\($0)" } ?? "未找到可用的 Theos 根目录"]
                           + diag.lines.map { "  \($0.ok ? "✓" : "✗") \($0.title)：\($0.detail)" })
                .joined(separator: "\n")
            return NativeBuildResult(ok: false, exitCode: -1, seconds: 0, artifacts: [], log: diagLog,
                                     message: "原生工具链不可用（缺少 Theos 运行时或 shell）")
        }
        let env = toolchain.environment(projectPath: config.projectPath)
        let result = await NativeCommandRunner.run(command: config.command,
                                                   in: config.projectPath,
                                                   environment: env,
                                                   timeout: config.timeout,
                                                   onLine: onLine,
                                                   onSpawn: onSpawn)
        let artifacts: [String]
        let foundMessage: String
        switch config.product {
        case .deb, .ipaShell:
            artifacts = toolchain.artifacts(in: config.projectPath)
            foundMessage = artifacts.isEmpty ? "构建成功，但没找到 .deb 产物" : "构建成功"
        case .dylib:
            if let dylib = IPAShellPacker.findBuiltDylib(in: config.projectPath) {
                artifacts = [dylib.path]
                foundMessage = "构建成功（dylib）"
            } else {
                artifacts = []
                foundMessage = "构建成功，但没找到 .dylib 产物"
            }
        }
        let message: String
        if result.timedOut {
            message = "构建超时（\(Int(config.timeout)) 秒）已终止"
        } else if result.ok {
            message = foundMessage
        } else {
            // [T-exit-code] 只报一个数字等于没报。134 = 128+6 = SIGABRT（编译器自己
            // abort，常见于内存不足或 clang 内部崩溃）；137/139 同理是信号而非普通退出。
            message = "构建失败（\(Self.explainExitCode(result.exitCode))）"
        }
        return NativeBuildResult(ok: result.ok, exitCode: result.exitCode,
                                 seconds: result.duration, artifacts: artifacts,
                                 log: result.output, message: message)
    }

    /// 把退出码翻译成人话。负数是我们自己造的语义值，>128 是 shell 的「信号」编码。
    nonisolated static func explainExitCode(_ code: Int32) -> String {
        switch code {
        case -1:
            return "退出码 -1 —— 进程根本没起来（工具链/shell 缺失或无法执行）"
        case 134:
            return "退出码 134（SIGABRT）—— 编译进程被 abort，常见于内存不足或 clang 内部崩溃"
        case 137:
            return "退出码 137（SIGKILL）—— 进程被系统杀掉，通常是内存不足"
        case 139:
            return "退出码 139（SIGSEGV）—— 编译器段错误"
        case 133:
            return "退出码 133（SIGTRAP）—— 断言失败"
        default:
            if code > 128 {
                return "退出码 \(code)（信号 \(code - 128)）"
            }
            return "退出码 \(code)"
        }
    }
}
