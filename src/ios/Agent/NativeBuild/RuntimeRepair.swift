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
        case .runtimeDamaged:
            return AppLocalized("Open Settings → Runtime diagnostics and tap One-tap repair: it reinstalls the incomplete runtime (shell / make / libraries).")
        case .spawnDenied, .dyldBlocked, .crashed, .timedOut, .unknown:
            return AppLocalized("Open Settings → Runtime diagnostics and tap One-tap repair: it rechecks the runtime and switches to iSH if native execution still fails. Only an external library-loading failure triggers a container copy.")
        }
    }

    /// 逐项诊断里「这个环境到底能不能原生执行」的结论。
    nonisolated static func environmentVerdict(_ report: MinisHostEnvironmentReport,
                                               health: NativeRuntimeHealth?) -> String {
        if let health, health.ok {
            return AppLocalized("Native runtime verified — commands can run natively.")
        }
        if !report.canRunNativeBinaries {
            return AppLocalized("This build has no detected native execution entitlements. Automatic mode stays in iSH; an explicit native startup probe is authoritative.")
        }
        return AppLocalized("The environment allows native execution but the runtime failed its startup probe. Tap One-tap repair.")
    }

    /// 把外部运行时复制进 App 容器。
    ///
    /// 仅对用户显式指定的外部路径尝试迁移，随后仍必须重新探针。
    /// 复制不会授予执行权限，也不能修复签名；已在容器内的树不重复复制。
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
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let supportPath = support.resolvingSymlinksInPath().path
        if resolvedRoot == supportPath || resolvedRoot.hasPrefix(supportPath + "/") {
            return (false, AppLocalized("The runtime is already inside the app container; copying it cannot repair signing or missing files."))
        }
        let source = NativeToolchain.runtimeRoot(forTheos: root)
        let relativeTheos = root.path == source.path ? "" : "theos"
        let dest = container.appendingPathComponent(source.lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return (false, AppLocalized("The runtime directory no longer exists: ") + source.path)
        }

        let errorText: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: container, withIntermediateDirectories: true)
                let staging = container.appendingPathComponent("import-" + UUID().uuidString)
                defer { try? fm.removeItem(at: staging) }
                try fm.copyItem(at: source, to: staging)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: dest)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        if let errorText {
            return (false, AppLocalized("Copy failed: ") + errorText)
        }
        let resolved = relativeTheos.isEmpty ? dest : dest.appendingPathComponent(relativeTheos, isDirectory: true)
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

        // 3) Only an external library-loading failure can benefit from relocation.
        // Never duplicate an app-owned damaged runtime before identifying its id.
        if health.failure == .dyldBlocked, let root = health.theosRoot {
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
                NativeToolchain.shared.resetCache()
                NativeRuntimeHealthMonitor.shared.invalidate()
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

    // MARK: - 单项修复

    /// 诊断页每一行失败都能单独修，不必再猜「一键修复」到底动了什么。
    ///
    /// 每个 id 对应 `RuntimeDiagnosticsView` 里的一行；返回的 steps 直接铺在
    /// 该行下面，用户能看到这一次到底做了什么。
    @MainActor
    static func repair(item id: String) async -> RuntimeRepairReport {
        var steps: [String] = []
        // 任何单项修复都先让探针重新说一次话，避免拿缓存里的旧结论下判断。
        NativeToolchain.shared.resetCache()
        NativeRuntimeHealthMonitor.shared.invalidate()
        MinisHostEnvironmentDetector.invalidateCache()

        switch id {
        case "native-spawn", "native-fs", "native-tcc", "shell":
            let host = MinisHostEnvironmentDetector.detect()
            steps.append(AppLocalized("Environment: ") + host.summary)
            var health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
            steps.append(AppLocalized("Probe: ") + health.summary)
            if health.failure == .dyldBlocked, let root = health.theosRoot {
                // libiosexec / 容器外 mmap 被拒：把运行时搬进 App 容器再试。
                let imported = await importRuntimeIntoContainer(from: root)
                steps.append(imported.message)
                if imported.ok {
                    health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
                    steps.append(AppLocalized("Probe after import: ") + health.summary)
                }
            }
            if health.ok {
                return RuntimeRepairReport(title: AppLocalized("Native execution works now"),
                                           steps: steps, resolved: true)
            }
            steps.append(AppLocalized("Still failing: ") + quickFixHint(for: health.failure))
            if !health.detail.isEmpty { steps.append(health.detail) }
            return RuntimeRepairReport(title: AppLocalized("Could not start a child process"),
                                       steps: steps, resolved: false)

        case "native-sign":
            return await resignInstalledRuntimes(steps: &steps)

        case "native-runtimes":
            return await reverifyInstalledRuntimes(steps: &steps)

        case "build", "native-build", "integrity":
            // libiosexec 加载不了 / mmap 被拒：先把运行时搬进 App 容器再试；
            // 真缺文件（截断、make 不在）才重装。
            var health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
            steps.append(AppLocalized("Probe: ") + health.summary)
            if health.failure == .dyldBlocked, let root = health.theosRoot {
                let imported = await importRuntimeIntoContainer(from: root)
                steps.append(imported.message)
                if imported.ok {
                    health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
                    steps.append(AppLocalized("Probe after import: ") + health.summary)
                }
            }
            if health.ok {
                return RuntimeRepairReport(title: AppLocalized("The toolchain runs now"),
                                           steps: steps, resolved: true)
            }
            return await reinstallTheosIfDamaged(steps: &steps)

        default:
            // 基础项（沙箱内核、通道、配置、文件）没有单独的动作，交给一键修复。
            return await oneClick()
        }
    }

    /// 签名层：把已装运行时的可执行文件按本 App 的 entitlements 重新签一遍。
    @MainActor
    private static func resignInstalledRuntimes(steps: inout [String]) async -> RuntimeRepairReport {
        let manager = DeveloperRuntimeManager.shared
        let installed = manager.runtimes.filter { manager.records[$0.id] != nil }
        guard !installed.isEmpty else {
            steps.append(AppLocalized("No runtime is installed, so there is nothing to re-sign."))
            return RuntimeRepairReport(title: AppLocalized("Nothing to sign"), steps: steps, resolved: false)
        }
        var signedTotal = 0
        var failedTotal = 0
        let canRun = MinisHostEnvironmentDetector.detect().canRunNativeBinaries
        if !canRun {
            steps.append(AppLocalized("This device cannot run native binaries, so ldid cannot sign anything here."))
        }
        for descriptor in installed {
            let root = DeveloperRuntimePaths.runtimeRoot(id: descriptor.id)
            let report = await signOffMainThread(descriptor: descriptor, root: root, canExecuteNative: canRun)
            manager.updateSigning(report, for: descriptor.id)
            signedTotal += report.signedCount
            failedTotal += max(report.failedPaths.count,
                               report.status == .failed || report.status == .skipped || report.signedCount == 0 ? 1 : 0)
            steps.append("\(descriptor.id): \(report.status.rawValue) · \(AppLocalized("signed")) \(report.signedCount)"
                         + (report.failedPaths.isEmpty ? "" : " · \(AppLocalized("failed")) \(report.failedPaths.count)"))
            if let reason = report.reason { steps.append("  " + reason) }
            if report.status == .failed {
                for path in report.failedPaths.prefix(3) { steps.append("  ✗ " + path) }
            }
        }
        if failedTotal == 0 {
            steps.append(AppLocalized("Signed ") + "\(signedTotal)")
            return RuntimeRepairReport(title: AppLocalized("Runtime binaries re-signed"),
                                       steps: steps, resolved: true)
        }
        steps.append(AppLocalized("Some binaries could not be signed. If ldid is missing, reinstall the Theos runtime (it ships its own ldid)."))
        return RuntimeRepairReport(title: AppLocalized("Signing partially failed"), steps: steps, resolved: false)
    }

    /// ldid 要真起子进程，几百个文件签下来是几十秒级的活。放在主线程上会
    /// 卡死界面、超过看门狗时限还会被系统直接杀掉，所以丢到后台队列。
    nonisolated private static func signOffMainThread(descriptor: RuntimeDescriptor,
                                                      root: URL,
                                                      canExecuteNative: Bool) async -> RuntimeSignReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<RuntimeSignReport, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let report = RuntimeSigner.signRuntime(descriptor: descriptor,
                                                       root: root,
                                                       canExecuteNative: canExecuteNative,
                                                       timeout: 90)
                continuation.resume(returning: report)
            }
        }
    }

    /// 自检：对已装运行时重跑清单里的探针，结论写回安装记录。
    @MainActor
    private static func reverifyInstalledRuntimes(steps: inout [String]) async -> RuntimeRepairReport {
        let manager = DeveloperRuntimeManager.shared
        let installed = manager.runtimes.filter { manager.records[$0.id] != nil }
        guard !installed.isEmpty else {
            steps.append(AppLocalized("No runtime is installed yet."))
            return RuntimeRepairReport(title: AppLocalized("Nothing to verify"), steps: steps, resolved: false)
        }
        var allPassed = true
        for descriptor in installed {
            let root = DeveloperRuntimePaths.runtimeRoot(id: descriptor.id)
            let report = await RuntimeInstallVerifier.verify(descriptor: descriptor,
                                                             root: root,
                                                             canExecuteNative: MinisHostEnvironmentDetector.cached.canRunNativeBinaries)
            manager.updateVerification(report, for: descriptor.id)
            steps.append("\(descriptor.id): \(report.status.rawValue)"
                         + (report.missingPaths.isEmpty ? "" : " · \(AppLocalized("missing")) \(report.missingPaths.count)")
                         + (report.reason.map { " · " + $0 } ?? ""))
            if report.status != .passed { allPassed = false }
        }
        return RuntimeRepairReport(title: allPassed ? AppLocalized("Every runtime passed its self-check")
                                                    : AppLocalized("Some runtimes failed their self-check"),
                                   steps: steps, resolved: allPassed)
    }

    /// Theos 运行时缺文件时重装；不缺就只解释当前结论。
    @MainActor
    private static func reinstallTheosIfDamaged(steps: inout [String]) async -> RuntimeRepairReport {
        var health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
        steps.append(AppLocalized("Probe: ") + health.summary)
        guard health.failure == .runtimeDamaged else {
            if health.ok {
                steps.append(AppLocalized("Native execution already works — nothing to reinstall."))
                return RuntimeRepairReport(title: AppLocalized("Nothing to repair"), steps: steps, resolved: true)
            }
            steps.append(AppLocalized("The runtime files are intact; the failure is elsewhere: ")
                         + quickFixHint(for: health.failure))
            return RuntimeRepairReport(title: AppLocalized("Runtime is not the problem"),
                                       steps: steps, resolved: false)
        }
        let runtimeID = installedRuntimeID(from: health.theosRoot)
        guard let runtimeID, let descriptor = DeveloperRuntimeManager.shared.runtimes.first(where: { $0.id == runtimeID }) else {
            steps.append(AppLocalized("The damaged runtime was not installed by Developer Runtime, so it cannot be reinstalled automatically. Install Theos from Settings → Developer Runtime."))
            return RuntimeRepairReport(title: AppLocalized("Cannot reinstall automatically"),
                                       steps: steps, resolved: false)
        }
        steps.append(AppLocalized("Reinstalling ") + runtimeID + "…")
        await DeveloperRuntimeManager.shared.installAndWait(descriptor)
        NativeToolchain.shared.resetCache()
        NativeRuntimeHealthMonitor.shared.invalidate()
        health = await NativeRuntimeHealthMonitor.shared.refresh(force: true)
        steps.append(AppLocalized("Probe after reinstall: ") + health.summary)
        return RuntimeRepairReport(title: health.ok ? AppLocalized("Runtime reinstalled")
                                                    : AppLocalized("Reinstall did not fix it"),
                                   steps: steps, resolved: health.ok)
    }

    /// 从 `DeveloperRuntime/installed/<id>/...` 里解出运行时 id。
    nonisolated static func installedRuntimeID(from path: String?) -> String? {
        guard let path else { return nil }
        let base = DeveloperRuntimePaths.installedRoot.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") else { return nil }
        return resolved.dropFirst(base.count + 1).split(separator: "/").first.map(String.init)
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
                return runtimeBinaryDamage(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) != nil
            }
            if damaged {
                manager.remove(id)
                if !FileManager.default.fileExists(atPath: dir.path) { removed.append(id) }
            }
        }
        if !removed.isEmpty {
            NativeToolchain.shared.resetCache()
            NativeRuntimeHealthMonitor.shared.invalidate()
        }
        return removed
    }
}
