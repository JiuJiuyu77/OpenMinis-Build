//
//  ToolExecutorPreference.swift
//  Minis — 工具执行器选择（沙箱 iSH / 原生 Runtime / 自动）
//
//  三个开关集中在这里，全部由 UserDefaults 持久化，供 shell_execute 与
//  编译工具在启动时读取一次并缓存：
//
//   1. executorMode        默认执行器：auto / sandbox / native
//   2. preferCustomRuntime 优先使用自定义 Runtime（Developer Runtime 安装的
//                          工具链）而不是 MT 共用那份
//   3. sandboxMode         强制沙箱模式：即使有原生工具链也只走 iSH
//
//  设计意图：默认行为与上游一致（auto + 不强制沙箱），用户显式选择后才改变。
//

import Foundation
import Combine

/// 谁执行 shell 命令。
enum ToolExecutorMode: String, CaseIterable, Identifiable {
    /// 有可用的原生工具链就用原生，否则回退 iSH。
    case auto
    /// 永远走 iSH 的 Alpine 沙箱（行为最接近上游）。
    case sandbox
    /// 永远走设备原生 Runtime；不可用时直接报错，不静默回退。
    case native

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return AppLocalized("Automatic")
        case .sandbox: return AppLocalized("Sandbox (iSH)")
        case .native: return AppLocalized("Native runtime")
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return AppLocalized("Use the on-device toolchain when it is installed and verified; otherwise stay in the iSH sandbox. If the runtime fails its startup probe, commands fall back to iSH automatically.")
        case .sandbox:
            return AppLocalized("Always run commands inside the sandboxed Alpine shell. Nothing runs natively on this device.")
        case .native:
            return AppLocalized("Always run commands with the on-device toolchain. Fails instead of falling back when it is missing.")
        }
    }
}

/// 用户对执行器的偏好。`@MainActor` 因为设置页直接绑定它。
@MainActor
final class ToolExecutorPreference: ObservableObject {

    static let shared = ToolExecutorPreference()

    private enum Key {
        static let mode = "toolExecutor.mode"
        static let preferCustomRuntime = "toolExecutor.preferCustomRuntime"
        static let sandboxMode = "toolExecutor.sandboxMode"
        static let reuseExternalRuntime = "nativeToolchain.reuseExternalRuntime"
    }

    @Published var mode: ToolExecutorMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Key.mode)
            NativeToolchain.shared.resetCache()
        }
    }

    /// 优先使用 Developer Runtime 里安装的那份工具链（Theos / OLLVM …），
    /// 而不是 MT-Agent 已经下载、被本 App 复用的那一份。
    @Published var preferCustomRuntime: Bool {
        didSet {
            defaults.set(preferCustomRuntime, forKey: Key.preferCustomRuntime)
            // 候选根的顺序变了，必须让 NativeToolchain 重新探测，否则旧的
            // 缓存会一直指向上一份工具链。
            NativeToolchain.shared.resetCache()
        }
    }

    /// 强制沙箱：即便原生工具链可用也不使用。等价于 `mode == .sandbox`，
    /// 但保留独立开关是因为它同时关掉原生编译类工具（不经过 shell 的那些）。
    @Published var sandboxMode: Bool {
        didSet {
            defaults.set(sandboxMode, forKey: Key.sandboxMode)
            NativeToolchain.shared.resetCache()
        }
    }

    /// 是否复用 MT-Agent / CodexApp 目录里的运行时。
    ///
    /// 默认关闭：那不是本 App 安装的 Theos。在沙箱构建里它既加载不了自己的
    /// 动态库（libiosexec 被 mmap 拦截），又会让「没装 Theos」在诊断页显示成
    /// 「已就绪」——两条都会把用户带进错误的方向。
    @Published var reuseExternalRuntime: Bool {
        didSet {
            defaults.set(reuseExternalRuntime, forKey: Key.reuseExternalRuntime)
            NativeToolchain.shared.resetCache()
        }
    }

    private let defaults: UserDefaults

    /// `defaults` 可注入，便于单元测试用独立的 suite。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Key.mode) ?? ToolExecutorMode.auto.rawValue
        self.mode = ToolExecutorMode(rawValue: raw) ?? .auto
        self.preferCustomRuntime = defaults.bool(forKey: Key.preferCustomRuntime)
        self.sandboxMode = defaults.bool(forKey: Key.sandboxMode)
        self.reuseExternalRuntime = defaults.bool(forKey: Key.reuseExternalRuntime)
    }

    /// 实际应当使用的执行器。三个开关收敛成一个决定，调用方不再各自重复。
    ///
    /// 规则只有两条：
    ///   1. 「沙箱」永远走 iSH；
    ///   2. 「自动」在环境不可能原生执行（非巨魔 / 非越狱 / 无 Theos）时走 iSH，
    ///      其余情况保持 auto —— 真正执行前还有一次探针，探针失败会回退 iSH。
    var resolvedExecutor: ToolExecutorMode {
        if sandboxMode { return .sandbox }
        if mode == .auto {
            if !MinisHostEnvironmentDetector.cached.environment.canRunNativeBinaries { return .sandbox }
            if !NativeToolchain.shared.isAvailable { return .sandbox }
        }
        return mode
    }

    /// 原生执行是否被允许（还没检查工具链是否存在）。
    var nativeExecutionAllowed: Bool {
        resolvedExecutor != .sandbox
    }

    /// 用户是否要求“自定义 Runtime 优先”。
    var customRuntimePreferred: Bool {
        preferCustomRuntime && !sandboxMode
    }

    /// 允许扫描其它 App 的运行时目录（MT-Agent / CodexApp）。
    var externalRuntimeAllowed: Bool {
        reuseExternalRuntime && !sandboxMode
    }

    /// 一次性把三个开关收敛成“这次命令该怎么跑”，供非主线程的调用方
    /// 在主线程上取值后带走，避免跨界反复读 `@Published` 属性。
    struct ExecutionDecision: Sendable {
        let executor: ToolExecutorMode
        let customRuntimePreferred: Bool
    }

    var executionDecision: ExecutionDecision {
        ExecutionDecision(executor: resolvedExecutor, customRuntimePreferred: customRuntimePreferred)
    }
}
