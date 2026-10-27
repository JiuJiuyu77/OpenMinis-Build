//
//  RuntimeEnvironment.swift
//  Minis — 运行环境识别 + 原生运行时健康检查 + 一键修复
//
//  背景：原生执行（NativeToolchain / NativeCommandRunner）的前提是
//  「App 真的能启动运行时的 Mach-O 二进制」。这件事只有三种环境可能成立：
//    · TrollStore（no-sandbox / platform-application）
//    · 无根越狱（/var/jb）
//    · 有根越狱
//  普通侧载 / App Store 沙箱里，运行时文件即使存在也 mmap 不了（典型报错
//  `Library not loaded: @rpath/libiosexec.1.dylib` + `file system sandbox
//  blocked mmap()`），进程会在 dyld 阶段 abort —— 也就是编译工作台里的
//  「退出码 134」，或 posix_spawn 直接失败「退出码 -1」。
//
//  以前只判断「文件在不在」，于是这种环境会一直选中原生执行，每条命令都
//  死在 libiosexec 上。这里补上两件事：
//    1. 环境识别：判断当前是巨魔 / 越狱 / 沙箱，并给出证据链；
//    2. 真实探针：真正 spawn 一次 shell，按输出把失败归类（dyld / spawn /
//       崩溃 / 超时），供执行器决策与「一键修复」使用。
//

import Foundation
import Combine

// MARK: - 环境识别

/// App 所处的安装环境。决定「设备原生执行」是否可能成立。
enum MinisHostEnvironment: String, Sendable {
    /// 巨魔安装：签名带 no-sandbox / platform-application。
    case trollStore
    /// 无根越狱（/var/jb）。
    case jailbreakRootless
    /// 有根越狱（/var/lib/dpkg、Cydia）。
    case jailbreakRootful
    /// 普通 App 沙箱（侧载 / App Store）。
    case appSandbox
    /// 探测不出来时保持中性，不阻断任何路径。
    case unknown

    var displayName: String {
        switch self {
        case .trollStore: return AppLocalized("TrollStore (巨魔)")
        case .jailbreakRootless: return AppLocalized("Jailbreak (rootless · 无根越狱)")
        case .jailbreakRootful: return AppLocalized("Jailbreak (rootful · 有根越狱)")
        case .appSandbox: return AppLocalized("Neither TrollStore nor jailbreak (沙箱)")
        case .unknown: return AppLocalized("Unknown")
        }
    }

    /// 是否可能直接执行设备原生二进制。
    var canRunNativeBinaries: Bool {
        switch self {
        case .trollStore, .jailbreakRootless, .jailbreakRootful: return true
        case .appSandbox, .unknown: return false
        }
    }
}

/// 一次环境探测的结果：结论 + 证据链。
struct MinisHostEnvironmentReport: Sendable {
    let environment: MinisHostEnvironment
    let sandboxed: Bool
    let evidence: [String]
    let checkedAt: Date

    var summary: String {
        let sandboxText = sandboxed
            ? AppLocalized("sandboxed")
            : AppLocalized("not sandboxed")
        return "\(environment.displayName) · \(sandboxText)"
    }

    /// 「原生执行能不能指望」的一句话结论。
    var nativeOutlook: String {
        if environment.canRunNativeBinaries && !sandboxed {
            return AppLocalized("Native execution is possible in this environment.")
        }
        return AppLocalized("Native execution is blocked here — commands stay in the iSH sandbox.")
    }
}

enum MinisHostEnvironmentDetector {

    private static let cacheLock = NSLock()
    private static var cachedReport: (report: MinisHostEnvironmentReport, at: Date)?

    /// 30 秒缓存：设置页、执行器、探针都会读，没必要每次都扫一遍文件系统。
    static var cached: MinisHostEnvironmentReport {
        cacheLock.lock()
        if let hit = cachedReport, Date().timeIntervalSince(hit.at) < 30 {
            cacheLock.unlock()
            return hit.report
        }
        cacheLock.unlock()
        let fresh = detect()
        cacheLock.lock()
        cachedReport = (fresh, Date())
        cacheLock.unlock()
        return fresh
    }

    static func invalidateCache() {
        cacheLock.lock()
        cachedReport = nil
        cacheLock.unlock()
    }

    /// 探测当前安装环境。纯本地判断，不发起网络请求，耗时以毫秒计。
    static func detect() -> MinisHostEnvironmentReport {
        let fm = FileManager.default
        var evidence: [String] = []

        // 1) 沙箱探测：能不能在 /var/mobile/Library/Caches 落一个文件。
        //    这是最诚实的判断——文件存在可以被伪造，写入权限不能。
        let sandboxed = !canWriteSharedCaches()
        evidence.append((sandboxed ? "✗ " : "✓ ") + "/var/mobile/Library/Caches " +
                        (sandboxed ? AppLocalized("not writable") : AppLocalized("writable")))

        // 2) 无根越狱：/var/jb。
        let hasVarJB = fm.fileExists(atPath: "/var/jb")
        if hasVarJB { evidence.append("✓ /var/jb") }

        // 3) 有根越狱：dpkg 数据库或 Cydia。
        let hasDpkg = fm.fileExists(atPath: "/var/lib/dpkg/status")
        let hasCydia = fm.fileExists(atPath: "/usr/libexec/cydia")
        if hasDpkg { evidence.append("✓ /var/lib/dpkg/status") }
        if hasCydia { evidence.append("✓ /usr/libexec/cydia") }

        // 4) 巨魔：TrollStore 的安装标记，或 App 自身路径里带 TrollStore。
        var trollStore = false
        for marker in ["/var/mobile/Library/TrollStore",
                       "/Applications/TrollStore.app",
                       "/var/containers/Bundle/Application/TrollStore.app"] {
            if fm.fileExists(atPath: marker) {
                trollStore = true
                evidence.append("✓ " + marker)
            }
        }
        if Bundle.main.bundleURL.path.lowercased().contains("trollstore") {
            trollStore = true
            evidence.append("✓ " + AppLocalized("bundle path contains TrollStore"))
        }

        let environment: MinisHostEnvironment
        if hasVarJB {
            // 无根越狱优先：/var/jb 是最硬的证据。
            environment = .jailbreakRootless
        } else if hasDpkg || hasCydia {
            environment = .jailbreakRootful
        } else if trollStore || !sandboxed {
            // 没有越狱标记、但进程能写出容器：巨魔安装（no-sandbox 生效）。
            environment = .trollStore
            if !trollStore { evidence.append("✓ " + AppLocalized("process is not sandboxed — TrollStore signature")) }
        } else {
            environment = .appSandbox
        }

        return MinisHostEnvironmentReport(environment: environment,
                                          sandboxed: sandboxed,
                                          evidence: evidence,
                                          checkedAt: Date())
    }

    private static func canWriteSharedCaches() -> Bool {
        let fm = FileManager.default
        let dir = "/var/mobile/Library/Caches"
        let probe = (dir as NSString).appendingPathComponent(".minis-env-probe-\(getpid())")
        guard fm.createFile(atPath: probe, contents: Data()) else { return false }
        try? fm.removeItem(atPath: probe)
        return true
    }
}

// MARK: - 运行时健康检查

/// 原生运行时为什么跑不起来。
enum NativeRuntimeFailure: String, Sendable, Equatable {
    case none
    /// 找不到 Theos 根目录。
    case toolchainMissing
    /// 有 Theos 但没有可执行的 shell。
    case shellMissing
    /// posix_spawn 被拒（EPERM / 无 no-sandbox）。
    case spawnDenied
    /// 子进程死在 dyld：libiosexec / @rpath 解析不了 / 沙箱拦截 mmap。
    case dyldBlocked
    /// 进程起来了但被信号打死（134 = SIGABRT，多数是 dyld abort）。
    case crashed
    case timedOut
    case unknown

    var isUsable: Bool { self == .none }

    var title: String {
        switch self {
        case .none: return AppLocalized("Ready")
        case .toolchainMissing: return AppLocalized("No Theos toolchain")
        case .shellMissing: return AppLocalized("No usable shell")
        case .spawnDenied: return AppLocalized("Cannot spawn the runtime shell")
        case .dyldBlocked: return AppLocalized("Runtime libraries cannot be loaded (libiosexec)")
        case .crashed: return AppLocalized("Runtime shell crashed")
        case .timedOut: return AppLocalized("Runtime shell timed out")
        case .unknown: return AppLocalized("Runtime check failed")
        }
    }

    /// 这类错误能不能靠「切回 iSH」立刻恢复。
    var workaroundIsSandbox: Bool {
        switch self {
        case .spawnDenied, .dyldBlocked, .crashed, .timedOut, .unknown: return true
        case .none, .toolchainMissing, .shellMissing: return false
        }
    }
}

/// 一次真实探针（spawn 一个 shell 并执行 printf）的结果。
struct NativeRuntimeHealth: Sendable {
    let failure: NativeRuntimeFailure
    let shell: String?
    let theosRoot: String?
    let exitCode: Int32
    let detail: String
    let checkedAt: Date

    var ok: Bool { failure == .none }

    var summary: String {
        if ok {
            return AppLocalized("Ready") + (shell.map { " · \($0)" } ?? "")
        }
        let reason = failure.title
        return detail.isEmpty ? reason : "\(reason) — \(detail)"
    }
}

/// 健康检查的单例缓存：执行器、编译工作台、设置页共用同一份结论。
@MainActor
final class NativeRuntimeHealthMonitor: ObservableObject {

    static let shared = NativeRuntimeHealthMonitor()

    @Published private(set) var health: NativeRuntimeHealth?
    @Published private(set) var checking = false

    /// 结论的保鲜期。运行时不会在几秒内自己变好，但重装/切执行器后要能立刻重测。
    private let ttl: TimeInterval = 90
    private var lastCheck: Date?

    private init() {}

    func invalidate() {
        health = nil
        lastCheck = nil
    }

    /// 取健康结论；`force` 为真时无条件重新探测。
    @discardableResult
    func refresh(force: Bool = false) async -> NativeRuntimeHealth {
        if !force, let cached = health, let stamp = lastCheck,
           Date().timeIntervalSince(stamp) < ttl {
            return cached
        }
        checking = true
        let result = await Self.probe()
        health = result
        lastCheck = Date()
        checking = false
        return result
    }

    /// 真正 spawn 一次 shell。逐个候选 shell 试，第一个跑通的即视为可用，
    /// 这样「zsh 依赖 libiosexec 挂了、但越狱自带 bash 还在」也能救回来。
    nonisolated static func probe() async -> NativeRuntimeHealth {
        let toolchain = NativeToolchain.shared
        guard let root = toolchain.theosRoot else {
            return NativeRuntimeHealth(failure: .toolchainMissing, shell: nil,
                                       theosRoot: nil, exitCode: 0, detail: "",
                                       checkedAt: Date())
        }
        guard toolchain.shellPath != nil else {
            return NativeRuntimeHealth(failure: .shellMissing, shell: nil,
                                       theosRoot: root.path, exitCode: 0, detail: "",
                                       checkedAt: Date())
        }

        let env = toolchain.environment()
        var firstFailure: NativeRuntimeHealth?
        // 最多试 5 个候选：每个 8 秒超时，12 个候选会把首屏拖到一分半。
        // 正常情况下第一个（运行时自带 shell）就会给出结论。
        for candidate in NativeCommandRunner.shellCandidates().prefix(5) {
            let result = await NativeCommandRunner.run(command: "printf MINIS_RUNTIME_OK",
                                                       in: NSTemporaryDirectory(),
                                                       environment: env,
                                                       timeout: 8,
                                                       shellOverride: candidate)
            if result.timedOut {
                firstFailure = firstFailure ?? NativeRuntimeHealth(
                    failure: .timedOut, shell: candidate, theosRoot: root.path,
                    exitCode: result.exitCode, detail: "", checkedAt: Date())
                continue
            }
            if result.exitCode == 0 && result.output.contains("MINIS_RUNTIME_OK") {
                return NativeRuntimeHealth(failure: .none, shell: candidate,
                                           theosRoot: root.path, exitCode: 0,
                                           detail: "", checkedAt: Date())
            }
            let classified = classify(output: result.output, exitCode: result.exitCode,
                                      shell: candidate, root: root.path)
            if firstFailure == nil { firstFailure = classified }
        }
        return firstFailure ?? NativeRuntimeHealth(failure: .unknown, shell: toolchain.shellPath,
                                                   theosRoot: root.path, exitCode: 0,
                                                   detail: "", checkedAt: Date())
    }

    nonisolated static func classify(output: String, exitCode: Int32,
                                     shell: String?, root: String) -> NativeRuntimeHealth {
        let lower = output.lowercased()
        let failure: NativeRuntimeFailure
        if lower.contains("libiosexec") || lower.contains("library not loaded")
            || lower.contains("symbol not found") || lower.contains("dyld") {
            failure = .dyldBlocked
        } else if lower.contains("could not start a process") || lower.contains("posix_spawn") {
            failure = .spawnDenied
        } else if exitCode == 134 {
            failure = .crashed
        } else if exitCode == 0 {
            failure = .unknown
        } else if exitCode == 127 {
            failure = .shellMissing
        } else {
            failure = .unknown
        }
        return NativeRuntimeHealth(failure: failure, shell: shell, theosRoot: root,
                                   exitCode: exitCode, detail: shortDetail(output),
                                   checkedAt: Date())
    }

    /// 从一坨日志里挑出最能说明问题的那一行。
    nonisolated static func shortDetail(_ output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        let markers = ["libiosexec", "library not loaded", "dyld", "could not start",
                       "posix_spawn", "sandbox"]
        if let hit = lines.first(where: { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }) {
            return hit.trimmingCharacters(in: .whitespaces)
        }
        return lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
