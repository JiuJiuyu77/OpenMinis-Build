//
//  BuiltinCapabilities.swift
//  Minis — App 内建能力的 provider
//
//  只读取既有管理器的状态，不复制、不缓存第二份真相：
//    * iSH 沙箱        → ISHKernel.shared.isBooted
//    * 原生工具链      → NativeToolchain.shared.isAvailable
//    * OLLVM           → DeveloperRuntimeManager 安装记录里的 provides
//    * iCloud 同步     → ICloudAvailability.isEntitled
//    * 工作区文件      → Application Support 可写
//
//  probe 必须廉价：这里全部是内存判断 + 少量 fileExists，不做下载或启动内核。
//

import Foundation

/// 内建能力的提供者。启动时由 `CapabilityRegistry.registerBuiltinsIfNeeded()`
/// 注册，providerIdentifier 固定为 `builtin`。
@MainActor
struct BuiltinCapabilities: CapabilityProviding {

    var providerIdentifier: String { "builtin" }

    var descriptors: [CapabilityDescriptor] {
        [
            CapabilityDescriptor(
                id: CapabilityID.sandboxShell,
                displayName: AppLocalized("Sandbox shell (iSH)"),
                kind: .execution,
                requires: [],
                summary: AppLocalized("Alpine Linux environment emulated on device.")),
            CapabilityDescriptor(
                id: CapabilityID.nativeExecution,
                displayName: AppLocalized("Native command execution"),
                kind: .execution,
                requires: [],
                summary: AppLocalized("Runs commands directly on iOS instead of inside the sandbox.")),
            CapabilityDescriptor(
                id: CapabilityID.iosToolchain,
                displayName: AppLocalized("iOS toolchain (Theos)"),
                kind: .toolchain,
                requires: [CapabilityID.nativeExecution],
                summary: AppLocalized("clang, ld64, ldid and DEB packaging for on-device builds.")),
            CapabilityDescriptor(
                id: CapabilityID.ollvm,
                displayName: AppLocalized("OLLVM obfuscating compiler"),
                kind: .toolchain,
                requires: [CapabilityID.iosToolchain],
                summary: AppLocalized("Protected compilation passes on top of the toolchain.")),
            CapabilityDescriptor(
                id: CapabilityID.workspaceFiles,
                displayName: AppLocalized("Workspace files"),
                kind: .filesystem,
                requires: [],
                summary: AppLocalized("Read and write files in the app's workspace.")),
            CapabilityDescriptor(
                id: CapabilityID.iCloudSync,
                displayName: AppLocalized("iCloud sync"),
                kind: .sync,
                requires: [],
                summary: AppLocalized("Sync sessions, skills and memory through iCloud.")),
            CapabilityDescriptor(
                id: CapabilityID.pluginHost,
                displayName: AppLocalized("Plugin host"),
                kind: .plugin,
                requires: [CapabilityID.workspaceFiles],
                summary: AppLocalized("Load plugins that contribute extra capabilities and tools.")),
        ]
    }

    func probe(_ id: String) -> CapabilityStatus? {
        let provider = providerIdentifier
        switch id {
        case CapabilityID.sandboxShell:
            // 沙箱在 App Store 构建里也应当可用；没起来只说明还没 boot。
            if ISHKernel.shared.isBooted {
                return .ok(id, provider: provider)
            }
            return .missing(id, reason: AppLocalized("The sandbox kernel is not running yet."), provider: provider)

        case CapabilityID.nativeExecution:
            guard ToolExecutorPreference.shared.nativeExecutionAllowed else {
                return .missing(id,
                                reason: AppLocalized("Disabled by the executor setting (sandbox mode)."),
                                provider: provider)
            }
            if NativeToolchain.shared.isAvailable {
                // [T-runtime-health] 「找到工具链」不等于「能启动」：沙箱构建里
                // 运行时文件看得见，但 shell 会死在 dyld（libiosexec），能力页
                // 以前却显示可用，用户只能等编译时拿一个 134。
                if let health = NativeRuntimeHealthMonitor.shared.health, !health.ok {
                    return .blocked(id, reason: health.summary, provider: provider)
                }
                return .ok(id, provider: provider)
            }
            return .missing(id,
                            reason: AppLocalized("No native toolchain was found on this device."),
                            provider: provider)

        case CapabilityID.iosToolchain:
            if NativeToolchain.shared.theosRoot != nil {
                return .ok(id, provider: provider)
            }
            // Developer Runtime 装好但尚未被 NativeToolchain 探测到时，
            // 给出可执行的下一步，而不是笼统的“不可用”。
            if RuntimeCapabilityNames.theosInstalled {
                return .missing(
                    id,
                    reason: AppLocalized("Installed by Developer Runtime but not detected yet — reopen Settings → Developer Runtime."),
                    provider: provider)
            }
            return .missing(id,
                            reason: AppLocalized("Install the Theos runtime from Settings → Developer Runtime."),
                            provider: provider)

        case CapabilityID.ollvm:
            if RuntimeCapabilityNames.ollvmInstalled {
                return .ok(id, provider: provider)
            }
            return .missing(id,
                            reason: AppLocalized("Install the OLLVM runtime from Settings → Developer Runtime."),
                            provider: provider)

        case CapabilityID.workspaceFiles:
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            guard let base, FileManager.default.isWritableFile(atPath: base.path) else {
                return .missing(id, reason: AppLocalized("Application Support is not writable."), provider: provider)
            }
            return .ok(id, provider: provider)

        case CapabilityID.iCloudSync:
            if ICloudAvailability.isEntitled {
                return .ok(id, provider: provider)
            }
            return .missing(id,
                            reason: ICloudAvailability.unavailabilityReason ?? AppLocalized("iCloud is not available."),
                            provider: provider)

        case CapabilityID.pluginHost:
            // 宿主始终可用；具体插件贡献的能力各自单独注册。
            return .ok(id, provider: provider)

        default:
            return nil
        }
    }
}
