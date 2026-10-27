//
//  RuntimeCapabilityNames.swift
//  Minis — 运行时能力标识的单一事实来源
//
//  为什么需要它：同一个 OLLVM 运行时在三个地方被判断过，三个地方各写了一
//  串不同的字符串（`ios.ollvm` / `ollvm` / `compiler.ollvm.frontend`），而
//  manifest 实际发布的是 `compiler.ollvm.frontend` +
//  `compiler.ollvm.obfuscation` + `compiler.ollvm.ios-artifact`。于是
//  「已经装好 OLLVM」在编译工作台里显示成「未安装」，选了混淆强度后又被
//  工具拒绝。把判断集中到这里，界面、工具、能力页就只有一个答案。
//

import Foundation

enum RuntimeCapabilityNames {
    /// manifest 中 Theos 运行时声明的能力。
    static let iosToolchain = "ios.toolchain"
    static let iosCompile = "ios.compile"

    /// manifest 中 OLLVM 运行时声明的能力（三种写法都算）。
    static let ollvmFrontend = "compiler.ollvm.frontend"
    static let ollvmObfuscation = "compiler.ollvm.obfuscation"
    /// 历史 / 兼容写法。
    static let ollvmLegacy = "ios.ollvm"
    static let ollvmShort = "ollvm"

    static let ollvmAliases: Set<String> = [
        ollvmFrontend, ollvmObfuscation, ollvmLegacy, ollvmShort,
    ]

    /// 已安装运行时提供的能力集合。
    @MainActor
    static var installed: Set<String> {
        DeveloperRuntimeManager.shared.installedCapabilities
    }

    /// OLLVM 是否可用。
    ///
    /// [T-ollvm-detect] 只看 manifest 声明会误报「缺失」：运行时的 manifest 里可能
    /// 根本没写 `compiler.ollvm.*`（OLLVM 前端是塞在 Theos 运行时的 usr/bin 里的），
    /// 于是装好了也显示未安装。所以声明没命中时，再问一次工具链本身——能找到一个
    /// 支持 `-mllvm` 的 clang，就算 OLLVM 真的可用。
    ///
    /// 探测要扫目录、读二进制头，不能放在 SwiftUI body 里每次渲染都做，因此缓存；
    /// 安装/卸载运行时后调用 `refreshOllvmProbe()` 让它失效。
    private static var ollvmProbeCache: Bool?

    @MainActor
    static func refreshOllvmProbe() {
        ollvmProbeCache = nil
    }

    @MainActor
    static var ollvmInstalled: Bool {
        if !installed.isDisjoint(with: ollvmAliases) { return true }
        if let cached = ollvmProbeCache { return cached }
        let probed = NativeToolchain.shared.findObfuscatingClang() != nil
        ollvmProbeCache = probed
        return probed
    }

    /// Theos 工具链是否由 Developer Runtime 安装（不代表探测成功）。
    @MainActor
    static var theosInstalled: Bool {
        installed.contains(iosToolchain) || installed.contains(iosCompile)
    }
}
