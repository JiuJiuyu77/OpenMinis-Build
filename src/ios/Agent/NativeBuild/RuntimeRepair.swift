//
//  RuntimeRepair.swift
//  Minis — 运行时故障的「针对性一键修复」
//
//  设计原则：运行时报错不静默吞掉，也不把用户卡死在一个裸错误码上。
//  每一类失败都有确定的、可执行的修复动作：
//    · 工具链不存在        → 引导安装（不假装能修）
//    · shell 缺失/损坏     → 重装运行时
//    · libiosexec/沙箱拦截 → ① 先把外部运行时复制进 App 容器再试（真正的修好）
//                            ② 仍不行就切回 iSH 沙箱（命令立刻可用）
//    · 探针超时 / 未知     → 清缓存重测一次，仍失败则切沙箱兜底
//

import Foundation

/// 一次「一键修复」的结果，直接展示在设置页里。
struct RuntimeRepairReport: Sendable, Identifiable {
    let id = UUID()
    var title: String
    var steps: [String]
    /// 修复后是否已经「可用」：原生跑起来了，或已经安全落到 iSH 沙箱。
    var resolved: Bool
}

enum RuntimeRepair {

    /// 针对某一类失败的修复建议（一句话）。日志、工具结果、构建失败都用它，
    /// 保证所有入口说的是同一件事。
    nonisolated static func quickFixHint(for failure: NativeRuntimeFailure) -> String {
        switch failure {
        case .none:
            return AppLocalized("Nothing to fix.")
        case .toolchainMissing:
            return AppLocalized("Install the Theos runtime from Settings → Developer Runtime.")
        case .shellMissing:
            return AppLocalized("Reinstall the Theos runtime — it has no usable shell inside.")
        case .spawnDenied, .dyldBlocked, .crashed, .timedOut, .unknown:
            return AppLocalized("Open Settings → Runtime diagnostics and tap One-tap repair: it copies the runtime into the app container, then switches to the iSH sandbox if native execution is still impossible.")
        }
    }

    /// 逐项诊断里「这个环境到底能不能原生执行」的结论。
    nonisolated static func environmentVerdict(_ report: MinisHostEnvironmentReport,
                                               health: NativeRuntimeHealth?) -> String {
        if let health, health.ok {
            return AppLocalized("Native runtime verified — commands can run natively.")
        }
        if !report.environment.canRunNativeBinaries || report.sandboxed {
            return AppLocalized("Neither TrollStore nor a jailbreak was detected, so the native runtime cannot load its own libraries (libiosexec). Everything is routed to the iSH sandbox.")
        }
        return AppLocalized("The environment allows native execution but the runtime failed its startup probe. Tap One-tap repair.")
    }

    /// 把外部运行时复制进 App 容器。
    ///
    /// 这是 libiosexec 的**根因修复**：运行时放在别的 App 目录或共享目录时，
    /// 沙箱会拦截 `mmap()`，dyld 直接 abort。复制到自己容器的
    /// `Library/Application Support/NativeToolchain/` 后，App 有完整读写权限，
    /// dylib 就能被正常映射。
    @MainActor
    static func importRuntimeIntoContainer(from theosRoot: String?) async -> (ok: Bool, message: String) {
        guard let rootPath = theosRoot, !rootPath.isEmpty else {
            return (false, AppLocalized("No Theos root to import."))
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            return (false, AppLocalized("App container is not available."))
        }
        let container = support.appendingPathComponent("NativeToolchain", isDirectory: true)
        if rootPath.hasPrefix(container.path) {
            return (true, AppLocalized("The runtime is already inside the app container."))
        }
        let source = URL(fileURLWithPath: rootPath).deletingLastPathComponent()
        let dest = container.appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            return (false, AppLocalized("The runtime directory no longer exists: ") + source.path)
        }

        let errorText: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let fm = FileManager.default
            do {
                try? fm.createDirectory(at: container, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        if let errorText {
            return (false, AppLocalized("Copy failed: ") + errorText)
        }
        let inner = dest.appendingPathComponent("theos", isDirectory: true)
        let resolved = fm.fileExists(atPath: inner.appendingPathComponent("makefiles/common.mk").path) ? inner : dest
        NativeToolchain.manualRootPath = resolved.path
        NativeToolchain.shared.resetCache()
        NativeRuntimeHealthMonitor.shared.invalidate()
        return (true, AppLocalized("Copied the runtime into the app container: ") + resolved.path)
    }

    /// 一键修复：清缓存 → 重新探针 → 按失败类型执行对应动作。
    @MainActor
    static func oneClick(removeDamagedRuntimes: Bool = false) async -> RuntimeRepairReport {
        var steps: [String] = []
        var resolved = false

        MinisHostEnvironmentDetector.invalidateCache()
        let host = MinisHostEnvironmentDetector.detect()
        steps.append(AppLocalized("Environment: ") + host.summary)
        if !host.evidence.isEmpty {
            steps.append(contentsOf: host.evidence.map { "· " + $0 })
        }

        if removeDamagedRuntimes {
            let removed = removeDamagedRuntimeDirectories()
            if removed.isEmpty {
                steps.append(AppLocalized("No damaged runtime directories found."))
            } else {
                steps.append(AppLocalized("Removed damaged runtimes: ") + removed.joined(separator: ", "))
            }
        }

        // 1) 清缓存，保证下面的探针不是从旧结论里读的。
        NativeToolchain.shared.resetCache()
        NativeRuntimeHealthMonitor.shared.invalidate()
        steps.append(AppLocalized("Cleared toolchain and probe caches."))

        // 2) 真跑一次 shell。
        var health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
        steps.append(AppLocalized("Probe: ") + health.summary)

        // 3) libiosexec / spawn 拒绝：先把运行时搬进 App 容器再试一次。
        if !health.ok, health.failure.workaroundIsSandbox, let root = health.theosRoot {
            let imported = await importRuntimeIntoContainer(from: root)
            steps.append(imported.message)
            if imported.ok {
                health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
                steps.append(AppLocalized("Probe after import: ") + health.summary)
            }
        }

        if health.ok {
            resolved = true
            steps.append(AppLocalized("Native execution is working again."))
            return RuntimeRepairReport(title: AppLocalized("Runtime repaired"), steps: steps, resolved: resolved)
        }

        // 4) 按失败类型收尾。
        switch health.failure {
        case .runtimeDamaged:
            // zsh / libiosexec / make 不完整：唯一可靠的修法是重新下载安装运行时。
            let runtimeID = installedRuntimeID(from: health.theosRoot)
            if let runtimeID,
               let descriptor = DeveloperRuntimeManager.shared.runtimes.first(where: { $0.id == runtimeID }) {
                steps.append(AppLocalized("Runtime files are incomplete — reinstalling ") + runtimeID + "…")
                await DeveloperRuntimeManager.shared.installAndWait(descriptor)
                health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
                steps.append(AppLocalized("Probe after reinstall: ") + health.summary)
                if health.ok {
                    resolved = true
                    return RuntimeRepairReport(title: AppLocalized("Runtime repaired"), steps: steps, resolved: true)
                }
            } else {
                steps.append(AppLocalized("The damaged runtime was not installed by Developer Runtime, so it cannot be reinstalled automatically. Install Theos from Settings → Developer Runtime."))
            }
            switchToSandboxIfNeeded(&steps)
            resolved = true

        case .toolchainMissing, .shellMissing:
            steps.append(AppLocalized("No usable Theos runtime was found — install it from Settings → Developer Runtime, then run One-tap repair again."))
            switchToSandboxIfNeeded(&steps)
            // 执行器已经在沙箱时，命令本身是可用的，只是原生编译能力缺失。
            resolved = true

        case .spawnDenied, .dyldBlocked, .crashed, .timedOut, .unknown:
            switchToSandboxIfNeeded(&steps)
            steps.append(AppLocalized("If you installed this app outside TrollStore/a jailbreak, native execution will never work here — that is expected, not a bug."))
            if let root = health.theosRoot {
                steps.append(AppLocalized("Runtime root: ") + root)
            }
            if !health.detail.isEmpty {
                steps.append(AppLocalized("Last error: ") + health.detail)
            }
            resolved = true

        case .none:
            resolved = true
        }

        return RuntimeRepairReport(title: resolved ? AppLocalized("Repair finished") : AppLocalized("Repair could not finish"),
                                   steps: steps,
                                   resolved: resolved)
    }

    /// 从 `DeveloperRuntime/installed/<id>/...` 里解出运行时 id。
    nonisolated static func installedRuntimeID(from path: String?) -> String? {
        guard let path else { return nil }
        let marker = "/DeveloperRuntime/installed/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        return rest.split(separator: "/").first.map(String.init)
    }

    /// 把执行器落到 iSH 沙箱，并把这一步写进报告。
    @MainActor
    private static func switchToSandboxIfNeeded(_ steps: inout [String]) {
        if !ToolExecutorPreference.shared.sandboxMode {
            ToolExecutorPreference.shared.sandboxMode = true
            steps.append(AppLocalized("Switched the executor to the iSH sandbox: the native runtime cannot start in this environment (blocked libiosexec / spawn denied)."))
        } else {
            steps.append(AppLocalized("The executor is already the iSH sandbox — commands keep working; the native runtime stays disabled until it can be verified."))
        }
    }

    /// 删除损坏（截断/非 Mach-O）的运行时目录，返回被删掉的运行时 id。
    /// 与 RuntimeDiagnosticsView 的损坏列表共用 `runtimeBinaryDamage`。
    @MainActor
    static func removeDamagedRuntimeDirectories() -> [String] {
        let manager = DeveloperRuntimeManager.shared
        let rels = ["usr/bin/zsh", "bin/zsh", "usr/bin/bash", "bin/bash",
                    "usr/bin/make", "usr/bin/clang"]
        var removed: [String] = []
        for id in manager.records.keys.sorted() {
            let dir = DeveloperRuntimePaths.installDirectory(id: id)
            let damaged = rels.contains { rel in
                let path = dir.appendingPathComponent(rel).path
                guard FileManager.default.fileExists(atPath: path) else { return false }
                return runtimeBinaryDamage(path) != nil
            }
            if damaged {
                try? FileManager.default.removeItem(at: dir)
                removed.append(id)
            }
        }
        if !removed.isEmpty {
            NativeToolchain.shared.resetCache()
            NativeRuntimeHealthMonitor.shared.invalidate()
        }
        return removed
    }
}
