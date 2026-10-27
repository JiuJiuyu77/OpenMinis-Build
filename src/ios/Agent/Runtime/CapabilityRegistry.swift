//
//  CapabilityRegistry.swift
//  Minis — 能力注册表（Capability Registry）
//
//  解决的问题：以前“这个工具现在能不能用”散落在各个管理器里
//  （Theos 是否装好、iSH 内核是否起来、iCloud 是否授权、插件是否启用……），
//  每个调用方各写一套判断，结果互相矛盾——例如设置页说“已安装”，
//  而 shell_execute 走的是另一条路。
//
//  这个注册表把所有能力收敛成**一个查询入口**：
//
//      CapabilityRegistry.shared.isAvailable(.iosToolchain)
//      CapabilityRegistry.shared.report()      // 全部能力 + 原因
//
//  能力来源分两类：
//    * 内建（builtin）：iSH 沙箱、原生 Theos、OLLVM、iCloud 同步、插件宿主……
//      provider 直接读现有管理器，不复制状态。
//    * 插件（plugin）：插件在 manifest 里声明 `capabilities`，
//      由 PluginCapabilityBridge 注册，插件卸载即自动移除。
//
//  这样 UI、工具层、诊断都问同一个对象，答案不会再互相矛盾。
//

import Foundation
import Combine

/// 一个可查询的能力。
struct CapabilityDescriptor: Identifiable, Equatable {
    enum Kind: String, Codable {
        /// 编译 / 打包 / 签名等原生工具链能力。
        case toolchain
        /// 命令执行（沙箱或原生）。
        case execution
        /// 文件与工作区读写。
        case filesystem
        /// iCloud / 网络同步。
        case sync
        /// 由插件提供的能力（不是 App 内建）。
        case plugin
        /// 其他自定义能力。
        case other
    }

    /// 稳定 id，外部（插件、脚本、诊断）用它查询，不要随 UI 改名。
    let id: String
    let displayName: String
    let kind: Kind
    /// 该能力依赖的其他能力 id。
    let requires: [String]
    /// 人类可读的补充说明（可为空）。
    let summary: String?

    init(id: String,
         displayName: String,
         kind: Kind,
         requires: [String] = [],
         summary: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.requires = requires
        self.summary = summary
    }
}

/// 一次探测的结果。
struct CapabilityStatus: Equatable {
    enum State: String {
        case available
        case unavailable
        /// 依赖某项能力缺失，本身没问题。
        case blocked

        var isUsable: Bool { self == .available }
    }

    let id: String
    let state: State
    /// 为什么不可用。为空表示可用。
    let reason: String?
    /// 提供者来源（builtin / plugin:<id>）。
    let provider: String

    static func ok(_ id: String, provider: String) -> CapabilityStatus {
        CapabilityStatus(id: id, state: .available, reason: nil, provider: provider)
    }

    static func missing(_ id: String, reason: String, provider: String) -> CapabilityStatus {
        CapabilityStatus(id: id, state: .unavailable, reason: reason, provider: provider)
    }

    static func blocked(_ id: String, reason: String, provider: String) -> CapabilityStatus {
        CapabilityStatus(id: id, state: .blocked, reason: reason, provider: provider)
    }
}

/// 能力提供者。任何一方想贡献能力，实现这个协议并注册。
///
/// `probe` 必须是**廉价、无副作用**的：注册表会在设置页刷新、工具调用前、
/// 诊断导出时调用它，不能在里面下载或启动内核。
@MainActor
protocol CapabilityProviding {
    var providerIdentifier: String { get }
    /// 声明该 provider 能回答哪些能力。
    var descriptors: [CapabilityDescriptor] { get }
    /// 返回某项能力的当前状态；不认识的 id 返回 nil。
    func probe(_ id: String) -> CapabilityStatus?
}

/// 全局能力注册表。
@MainActor
final class CapabilityRegistry: ObservableObject {

    static let shared = CapabilityRegistry()

    /// 状态变化时递增，供 SwiftUI 观察（`@ObservedObject` + `.onChange`）。
    @Published private(set) var revision: Int = 0

    private var providers: [String: CapabilityProviding] = [:]
    /// 注册顺序决定同名能力的优先提供者（先注册者优先）。
    private var providerOrder: [String] = []

    init() {}

    // MARK: - 注册

    /// 注册一个 provider。重复注册同一个 `providerIdentifier` 会替换旧的。
    func register(_ provider: CapabilityProviding) {
        let key = provider.providerIdentifier
        if providers[key] == nil { providerOrder.append(key) }
        providers[key] = provider
        bump()
    }

    /// 注销（插件卸载时调用）。
    func unregister(providerIdentifier: String) {
        guard providers.removeValue(forKey: providerIdentifier) != nil else { return }
        providerOrder.removeAll { $0 == providerIdentifier }
        bump()
    }

    /// 已经在注册表里的 provider id。
    var registeredProviders: [String] { providerOrder }

    /// 注册 App 内建能力。幂等，启动时调用一次。
    ///
    /// 除了 `builtin`（工具链/iSH/iCloud…）还注册 `openai`：模型侧的“能力”
    /// 来自用户的 Provider 配置，与工具链无关，但两者都必须在同一个注册表
    /// 里回答，否则设置页与工具预检会各说各话。
    func registerBuiltinsIfNeeded() {
        if providers["builtin"] == nil { register(BuiltinCapabilities()) }
        if providers["openai"] == nil { register(OpenAICapabilities()) }
    }

    // MARK: - 查询

    /// 全部能力描述（内建 + 插件），按 provider 注册顺序排列。
    var allDescriptors: [CapabilityDescriptor] {
        providerOrder.flatMap { providers[$0]?.descriptors ?? [] }
    }

    /// 某项能力是否可用。未知能力一律 false——“没声明”不等于“有”。
    func isAvailable(_ id: String) -> Bool {
        status(for: id).state.isUsable
    }

    /// 单项能力的详细状态。
    func status(for id: String) -> CapabilityStatus {
        let descriptor = descriptor(for: id)

        // 未知能力：明确报不可用，不假装成功。
        guard let descriptor else {
            return .missing(id, reason: "Unknown capability", provider: "none")
        }

        // 依赖先决：任一依赖不可用则 blocked（区别于“本身坏了”）。
        for dependency in descriptor.requires {
            let depStatus = status(for: dependency)
            if !depStatus.state.isUsable {
                return .blocked(
                    id,
                    reason: "Requires \(dependency) (\(depStatus.reason ?? "unavailable"))",
                    provider: owningProvider(for: id)
                )
            }
        }

        // 第一个认识它的 provider 说了算。
        for key in providerOrder {
            if let status = providers[key]?.probe(id) { return status }
        }
        return .missing(id, reason: "No provider answered", provider: owningProvider(for: id))
    }

    /// 全部能力的状态快照，供诊断页 / `minis-config` 展示。
    func report() -> [CapabilityStatus] {
        allDescriptors.map { status(for: $0.id) }
    }

    /// 诊断用的纯文本表（设置页「能力」区块与日志共用）。
    func reportText() -> String {
        let rows = report().map { status -> String in
            let mark: String
            switch status.state {
            case .available: mark = "OK   "
            case .blocked: mark = "BLOCK"
            case .unavailable: mark = "MISS "
            }
            let suffix = status.reason.map { " — \($0)" } ?? ""
            return "\(mark) \(status.id) [\(status.provider)]\(suffix)"
        }
        return (["Capability report:"] + rows).joined(separator: "\n")
    }

    /// 让 UI 主动刷新一次（例如安装完运行时之后）。
    func refresh() { bump() }

    // MARK: - Helpers

    func descriptor(for id: String) -> CapabilityDescriptor? {
        for key in providerOrder {
            if let d = providers[key]?.descriptors.first(where: { $0.id == id }) { return d }
        }
        return nil
    }

    private func owningProvider(for id: String) -> String {
        for key in providerOrder {
            if providers[key]?.descriptors.contains(where: { $0.id == id }) == true { return key }
        }
        return "none"
    }

    private func bump() { revision &+= 1 }
}

// MARK: - 内建能力 id

/// 内建能力的稳定 id 常量。插件与脚本按这些字符串查询，因此不要改名。
enum CapabilityID {
    /// iSH 的 Alpine 沙箱可以执行命令。
    static let sandboxShell = "shell.sandbox"
    /// 设备原生工具链（Theos）可执行编译/打包/签名。
    static let iosToolchain = "ios.toolchain"
    /// OLLVM 混淆编译器可用。
    static let ollvm = "ios.ollvm"
    /// 原生命令执行（不经过 iSH）。
    static let nativeExecution = "exec.native"
    /// 工作区文件读写。
    static let workspaceFiles = "fs.workspace"
    /// iCloud 同步（需要 iCloud entitlement）。
    static let iCloudSync = "sync.icloud"
    /// 插件宿主本身可用。
    static let pluginHost = "plugin.host"

    // 以下 id 直接对齐运行时清单的 `provides`，这样「装了 Node 运行时」
    // 就能用清单里的名字查询，不必再维护一套别名。
    /// Node.js 运行时（node.javascript）。
    static let nodeRuntime = "node.javascript"
    /// CPython 运行时（python.runtime）。
    static let pythonRuntime = "python.runtime"
    /// 基础开发工具（core.git / rg / curl / jq …）。
    static let coreTools = "core.git"
    /// CMake + Ninja（build.cmake）。
    static let buildTools = "build.cmake"
    /// radare2 / mt-macho（reverse.radare2）。
    static let reverseTools = "reverse.radare2"

    /// 由 Developer Runtime 安装后才会出现的能力。
    static let developerRuntimeCapabilities = [nodeRuntime, pythonRuntime,
                                               coreTools, buildTools, reverseTools]
}
