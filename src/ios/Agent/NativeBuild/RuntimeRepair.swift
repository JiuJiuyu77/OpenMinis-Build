//
//  RuntimeRepair.swift
//  Minis — 运行时故障的「针对性一键修复」
//
//  设计原则：运行时报错不静默吞掉，也不把用户卡死在一个裸错误码上。
//  每一类失败都有一个确定的、可执行的修复动作：
//    · 工具链不存在        → 引导安装（不假装能修）
//    · shell 缺失/损坏     → 重装运行时
//    · libiosexec/沙箱拦截 → 自动切回 iSH 沙箱（命令立刻恢复可用），
//                            同时清掉探测缓存，等用户装好巨魔/越狱版再自动切回
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
            return AppLocalized("Open Settings → Runtime diagnostics and tap One-tap repair: it switches the executor to the iSH sandbox and clears the cached probe.")
        }
    }

    /// 逐项诊断里「这个环境到底能不能原生执行」的结论。
    nonisolated static func environmentVerdict(_ report: MinisHostEnvironmentReport,
                                               health: NativeRuntimeHealth?) -> String {
        if let health, health.ok {
            return AppLocalized("Native runtime verified — commands can run natively.")
        }
        if !report.environment.canRunNativeBinaries || report.sandboxed {
            return AppLocalized("This build runs inside the app sandbox, so the native runtime cannot load its own libraries (libiosexec). Everything is routed to the iSH sandbox.")
        }
        return AppLocalized("The environment allows native execution but the runtime failed its startup probe. Tap One-tap repair.")
    }

    /// 一键修复：清缓存 → 重新探针 → 按失败类型执行对应动作。
    ///
    /// - Parameter removeDamagedRuntimes: 是否顺带删掉「截断/损坏」的运行时目录
    ///   （运行时诊断页的损坏列表用的就是同一份判断）。默认 false：
    ///   删除是破坏性操作，只在用户明确点了相应按钮时才做。
    @MainActor
    static func oneClick(removeDamagedRuntimes: Bool = false) async -> RuntimeRepairReport {
        var steps: [String] = []
        var resolved = false

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
        let health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
        steps.append(AppLocalized("Probe: ") + health.summary)

        if health.ok {
            resolved = true
            return RuntimeRepairReport(title: AppLocalized("Runtime repaired"), steps: steps, resolved: resolved)
        }

        // 3) 按失败类型处理。
        switch health.failure {
        case .toolchainMissing, .shellMissing:
            steps.append(AppLocalized("No usable Theos runtime was found — install it from Settings → Developer Runtime, then run One-tap repair again."))
            // 工具链缺失时仍然允许把执行器落到沙箱，避免所有命令不可用。
            if !ToolExecutorPreference.shared.sandboxMode {
                ToolExecutorPreference.shared.sandboxMode = true
                steps.append(AppLocalized("Switched the executor to the iSH sandbox so commands keep working."))
            } else {
                steps.append(AppLocalized("The executor is already the iSH sandbox — commands keep working; the native runtime stays disabled until it can be verified."))
            }
            // 执行器已经在沙箱时，命令本身是可用的，只是原生编译能力缺失。
            resolved = true

        case .spawnDenied, .dyldBlocked, .crashed, .timedOut, .unknown:
            if !ToolExecutorPreference.shared.sandboxMode {
                ToolExecutorPreference.shared.sandboxMode = true
                steps.append(AppLocalized("Switched the executor to the iSH sandbox: the native runtime cannot start in this environment (blocked libiosexec / spawn denied)."))
                resolved = true
            } else {
                steps.append(AppLocalized("The executor is already the iSH sandbox — commands keep working; the native runtime stays disabled until it can be verified."))
                resolved = true
            }
            steps.append(AppLocalized("If you installed this app outside TrollStore/a jailbreak, native execution will never work here — that is expected, not a bug."))
            if let root = health.theosRoot {
                steps.append(AppLocalized("Runtime root: ") + root)
            }
            if !health.detail.isEmpty {
                steps.append(AppLocalized("Last error: ") + health.detail)
            }

        case .none:
            resolved = true
        }

        return RuntimeRepairReport(title: resolved ? AppLocalized("Repair finished") : AppLocalized("Repair could not finish"),
                                   steps: steps,
                                   resolved: resolved)
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
