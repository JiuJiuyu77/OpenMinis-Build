//
//  RuntimeDiagnosticsView.swift
//  Minis — 运行时诊断（设置 › 运行时诊断）
//
//  一个页面回答四个问题，全部来自本机真实探测，不发网络请求：
//    1. 工具链在不在？在哪？缺哪一步？
//    2. Developer Runtime 装了哪些、还缺哪些、各自声称提供什么能力？
//    3. 混淆（OLLVM）到底算不算可用？（这是「无法识别 OLLVM」的直接答案）
//    4. 执行器当前会走 iSH 还是原生？为什么？
//

import SwiftUI

struct RuntimeDiagnosticsView: View {

    @ObservedObject private var manager = DeveloperRuntimeManager.shared
    @ObservedObject private var preference = ToolExecutorPreference.shared
    @ObservedObject private var healthMonitor = NativeRuntimeHealthMonitor.shared
    @State private var manualRoot = NativeToolchain.manualRootPath ?? ""
    @State private var refreshedAt = Date()
    @State private var repairing = false
    @State private var repairReport: RuntimeRepairReport?

    var body: some View {
        Form {
            summarySection
            environmentSection
            repairSection
            toolchainSection
            ollvmSection
            runtimesSection
            runtimeHealthSection
            executorSection
        }
        .navigationTitle(Text(verbatim: "运行时诊断"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    recheck()
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            Task { await manager.loadManifestIfNeeded() }
            Task { await healthMonitor.refresh() }
        }
    }

    private func recheck() {
        NativeToolchain.shared.resetCache()
        NativeRuntimeHealthMonitor.shared.invalidate()
        ICloudAvailability.resetCache()
        refreshedAt = Date()
        Task { await healthMonitor.refresh(force: true) }
    }

    // MARK: - 环境识别（巨魔 / 越狱 / 沙箱）

    /// 回答「这台设备到底能不能跑原生二进制」。以前只显示「工具链找到没」，
    /// 于是沙箱构建里明明看得见 MT 的 TheosRuntime、却每条命令都死在
    /// libiosexec 上，诊断页还是一片绿。
    private var environmentSection: some View {
        Section {
            let host = MinisHostEnvironmentDetector.detect()
            row(title: AppLocalized("Host environment"),
                detail: host.summary,
                ok: host.environment.canRunNativeBinaries && !host.sandboxed)
            ForEach(Array(host.evidence.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            let health = healthMonitor.health
            row(title: AppLocalized("Startup probe"),
                detail: healthMonitor.checking
                    ? AppLocalized("Checking…")
                    : (health?.summary ?? AppLocalized("Not checked yet")),
                ok: health?.ok ?? false)
            Text(RuntimeRepair.environmentVerdict(host, health: health))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "环境识别")
        } footer: {
            Text(verbatim: "判断依据是真实写入权限与一次真实 spawn，不是只看文件在不在。普通侧载 / App Store 构建即使能看到 Theos 运行时，也会卡在 libiosexec，这时命令应全部留在 iSH 沙箱。")
        }
    }

    // MARK: - 一键修复

    private var repairSection: some View {
        Section {
            Button {
                repairing = true
                Task {
                    let report = await RuntimeRepair.oneClick()
                    repairReport = report
                    repairing = false
                    recheck()
                }
            } label: {
                Label(AppLocalized("One-tap repair"), systemImage: "wrench.and.screwdriver.fill")
            }
            .disabled(repairing)
            if repairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(AppLocalized("Repairing…")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let report = repairReport {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: report.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(report.resolved ? Color.green : Color.orange)
                    ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                        Text(verbatim: step)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(verbatim: "一键修复")
        } footer: {
            Text(verbatim: "清缓存 → 重新探针 → 按失败类型处理：libiosexec / 沙箱拦截会直接切回 iSH 沙箱并说明原因；运行时损坏会在上面的列表里标出并可删除后重装。")
        }
    }


    // MARK: - 运行时完整性（损坏 → 只能重装）

    /// 沙盒是独立 chroot：它既看不见设备侧的 DeveloperRuntime 目录，也没有写权限，
    /// 所以运行时二进制损坏**不可能**在沙盒内修好，只能删掉损坏目录后由 App 重装。
    /// 这里把损坏项直接列出来，并给一个针对性的清除入口。
    private var runtimeHealthSection: some View {
        Section {
            let damaged = damagedRuntimeBinaries()
            if damaged.isEmpty {
                row(title: AppLocalized("Runtime binaries"),
                    detail: AppLocalized("All present binaries look intact"),
                    ok: true)
            } else {
                ForEach(damaged, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: item.path).font(.caption).foregroundStyle(.red)
                        Text(verbatim: item.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) {
                    for id in Set(damaged.map(\.runtimeID)) {
                        try? FileManager.default.removeItem(
                            at: DeveloperRuntimePaths.installDirectory(id: id))
                    }
                    recheck()
                } label: {
                    Label(AppLocalized("Delete damaged runtimes and reinstall"),
                          systemImage: "trash")
                }
            }
        } header: {
            Text(AppLocalized("Runtime integrity"))
        } footer: {
            Text(AppLocalized("A truncated binary (e.g. a few dozen bytes) cannot be repaired inside the iSH sandbox — it is an isolated chroot. Deleting it here and reinstalling from the list above is the only fix."))
        }
    }

    private struct DamagedRuntimeBinary: Identifiable {
        let runtimeID: String
        let path: String
        let reason: String
        var id: String { path }
    }

    private func damagedRuntimeBinaries() -> [DamagedRuntimeBinary] {
        let rels = ["usr/bin/zsh", "bin/zsh", "usr/bin/bash", "bin/bash",
                    "usr/bin/make", "usr/bin/clang"]
        var out: [DamagedRuntimeBinary] = []
        for id in manager.records.keys.sorted() {
            let dir = DeveloperRuntimePaths.installDirectory(id: id)
            for rel in rels {
                let path = dir.appendingPathComponent(rel).path
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if let why = runtimeBinaryDamage(path) {
                    out.append(DamagedRuntimeBinary(runtimeID: id, path: path, reason: why))
                }
            }
        }
        return out
    }

    // MARK: - 概览

    private var summarySection: some View {
        Section {
            let toolchain = NativeToolchain.shared
            row(title: AppLocalized("Native toolchain"),
                detail: toolchain.isAvailable
                    ? (toolchain.rootPath.isEmpty ? AppLocalized("Ready") : toolchain.rootPath)
                    : AppLocalized("Not found"),
                ok: toolchain.isAvailable)
            row(title: AppLocalized("OLLVM"),
                detail: RuntimeCapabilityNames.ollvmInstalled
                    ? AppLocalized("Installed — obfuscation available")
                    : AppLocalized("Not installed"),
                ok: RuntimeCapabilityNames.ollvmInstalled)
            row(title: AppLocalized("Effective executor"),
                detail: preference.resolvedExecutor.displayName,
                ok: true)
            row(title: AppLocalized("Checked"),
                detail: refreshedAt.formatted(date: .omitted, time: .standard),
                ok: true)
        } header: {
            Text(verbatim: "概览")
        } footer: {
            Text(verbatim: "点右上角刷新会清掉工具链与 iCloud 的探测缓存，然后重新扫描。")
        }
    }

    // MARK: - 工具链逐项

    private var toolchainSection: some View {
        Section {
            let diag = NativeToolchain.shared.diagnostics()
            ForEach(Array(diag.lines.enumerated()), id: \.offset) { _, line in
                row(title: line.title, detail: line.detail, ok: line.ok)
            }
            TextField("Theos root path", text: $manualRoot)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button("Apply and re-detect") {
                    NativeToolchain.manualRootPath = manualRoot
                    manualRoot = NativeToolchain.manualRootPath ?? ""
                    recheck()
                }
                .disabled(manualRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Clear", role: .destructive) {
                    manualRoot = ""
                    NativeToolchain.manualRootPath = nil
                    recheck()
                }
            }
            .font(.footnote)
        } header: {
            Text(verbatim: "工具链逐项")
        } footer: {
            Text(verbatim: "Shell 一行显示实际会用哪个 shell。运行时只带 zsh 时这里应显示 usr/bin/zsh；若是「未找到」，编译一定失败。")
        }
    }

    // MARK: - OLLVM

    private var ollvmSection: some View {
        Section {
            let installed = RuntimeCapabilityNames.installed
            row(title: AppLocalized("OLLVM capability"),
                detail: RuntimeCapabilityNames.ollvmInstalled ? AppLocalized("Yes") : AppLocalized("No"),
                ok: RuntimeCapabilityNames.ollvmInstalled)
            ForEach(RuntimeCapabilityNames.ollvmAliases.sorted(), id: \.self) { name in
                row(title: name, detail: installed.contains(name) ? AppLocalized("provided") : AppLocalized("absent"),
                    ok: installed.contains(name))
            }
            let obfuscator = NativeToolchain.shared.findObfuscatingClang()
            row(title: AppLocalized("OLLVM clang"),
                detail: obfuscator ?? AppLocalized("Not found — install the OLLVM runtime"),
                ok: obfuscator != nil)
        } header: {
            Text(verbatim: "混淆（OLLVM）")
        } footer: {
            Text(verbatim: "任意一个别名命中即视为已安装。若「能力」为 No 但 runtime 已装好，说明 manifest 的 provides 与本机记录不一致，重装该运行时即可。")
        }
    }

    // MARK: - 运行时清单

    private var runtimesSection: some View {
        Section {
            if manager.runtimes.isEmpty {
                Text(manager.isLoadingManifest ? "Loading manifest…" : "No runtimes in the manifest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.runtimes) { descriptor in
                    let state = manager.state(for: descriptor)
                    row(title: descriptor.displayName,
                        detail: stateDetail(state, descriptor),
                        ok: state.isInstalled)
                }
            }
            Button {
                Task { await manager.refreshManifest() }
            } label: {
                Label("Refresh manifest", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.isLoadingManifest)
        } header: {
            Text(verbatim: "运行时清单")
        } footer: {
            Text(verbatim: "安装/更新/移除在 设置 → Developer Runtime 里操作。这里只读，用来确认状态。")
        }
    }

    private func stateDetail(_ state: RuntimeInstallState, _ descriptor: RuntimeDescriptor) -> String {
        switch state {
        case .installed(let record):
            return String(format: AppLocalized("Installed %@"), record.version)
        case .outdated(let record):
            return String(format: AppLocalized("Outdated %@ → %@"), record.version, descriptor.version)
        case .notInstalled:
            return AppLocalized("Not installed")
        }
    }

    // MARK: - 执行器

    private var executorSection: some View {
        Section {
            LabeledContent("Executor", value: preference.resolvedExecutor.displayName)
            LabeledContent("Prefer custom runtime",
                           value: preference.preferCustomRuntime ? AppLocalized("On") : AppLocalized("Off"))
            LabeledContent("Sandbox mode",
                           value: preference.sandboxMode ? AppLocalized("On") : AppLocalized("Off"))
            Text(preference.resolvedExecutor.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "执行器")
        } footer: {
            Text(verbatim: "「自动」默认留在 iSH，只有打开「优先使用自定义 Runtime」才会切到本机工具链。")
        }
    }

    // MARK: - 行

    private func row(title: String, detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.caption.weight(.medium))
                Text(verbatim: detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
