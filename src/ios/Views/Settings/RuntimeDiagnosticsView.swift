//
//  RuntimeDiagnosticsView.swift
//  Minis — 运行诊断（设置 › 运行时诊断）
//
//  版式参照 MT-Agent 的「运行诊断」：顶部是一张总体状态卡，下面按
//  基础运行 / 项目能力 / 可选能力 分组，每项都是「图标 + 标题 + 状态说明 +
//  右侧转圈/对勾」。所有检查都是真跑，不是静态标记：
//    · 沙箱内核   → ISHKernel 是否 boot
//    · 命令执行   → 在 guest 里真的 echo 一次
//    · 实时工具通道 → /usr/local/bin 的原生 offload 占位命令是否在
//    · 运行配置   → ProviderConfigDB 能否读到
//    · 项目文件   → Application Support 能否读写
//    · Git / 代码辅助 → guest 里 git / rg 是否可用
//    · 手机编译   → NativeToolchain + 真实启动探针
//

import SwiftUI

// MARK: - 检查项

struct RuntimeDiagItem: Identifiable {
    enum Status: Equatable {
        case pending
        case running
        case ok
        case failed(String)
        case skipped(String)
    }

    let id: String
    let title: String
    let icon: String
    let tint: [Color]
    /// 空闲时展示的固定说明（例如「iSH Alpine 模拟层」）。
    let subtitle: String
    var status: Status = .pending
    var detail: String = ""
}

// MARK: - 控制器

@MainActor
final class RuntimeDiagnosticsModel: ObservableObject {

    @Published private(set) var running = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var finishedAt: Date?

    @Published var basic: [RuntimeDiagItem] = [
        .init(id: "kernel", title: AppLocalized("Sandbox kernel"), icon: "shippingbox.fill",
              tint: [.blue, .cyan], subtitle: AppLocalized("iSH Alpine emulation layer")),
        .init(id: "shell", title: AppLocalized("Command execution"), icon: "terminal.fill",
              tint: [.blue, .indigo], subtitle: AppLocalized("Runs a real command inside the sandbox")),
        .init(id: "bridge", title: AppLocalized("Realtime tool bridge"), icon: "bolt.horizontal.fill",
              tint: [.teal, .blue], subtitle: AppLocalized("Native offload commands (apple-* / minis-*)")),
        .init(id: "config", title: AppLocalized("Runtime configuration"), icon: "slider.horizontal.3",
              tint: [.indigo, .purple], subtitle: AppLocalized("Provider configuration database")),
        .init(id: "files", title: AppLocalized("Project files"), icon: "folder.fill",
              tint: [.blue, .teal], subtitle: AppLocalized("Workspace and Application Support are readable")),
    ]

    @Published var project: [RuntimeDiagItem] = [
        .init(id: "git", title: AppLocalized("Git & common tools"), icon: "arrow.triangle.branch",
              tint: [.orange, .pink], subtitle: AppLocalized("git / tar / curl inside the sandbox")),
        .init(id: "search", title: AppLocalized("Code assistance"), icon: "magnifyingglass",
              tint: [.purple, .blue], subtitle: AppLocalized("ripgrep and friends")),
    ]

    @Published var optional: [RuntimeDiagItem] = [
        .init(id: "build", title: AppLocalized("On-device compiling"), icon: "hammer.fill",
              tint: [.green, .teal], subtitle: AppLocalized("Theos toolchain and native runtime")),
        .init(id: "integrity", title: AppLocalized("Runtime integrity"), icon: "checkmark.shield.fill",
              tint: [.mint, .green], subtitle: AppLocalized("zsh / libiosexec / make")),
        .init(id: "environment", title: AppLocalized("Host environment"), icon: "iphone.gen3",
              tint: [.gray, .blue], subtitle: AppLocalized("TrollStore or jailbreak")),
    ]

    private var timerTask: Task<Void, Never>?

    var allItems: [RuntimeDiagItem] { basic + project + optional }
    var failedCount: Int {
        allItems.filter { if case .failed = $0.status { return true }; return false }.count
    }
    var passedCount: Int {
        allItems.filter { $0.status == .ok }.count
    }

    var overallTitle: String {
        if running {
            return AppLocalized("Checking core capabilities…")
        }
        if failedCount > 0 {
            return String(format: AppLocalized("%ld checks need attention"), failedCount)
        }
        return AppLocalized("All checks passed")
    }

    var overallSubtitle: String {
        if running {
            let pending = allItems.filter { $0.status == .pending }.map(\.title)
            let head = pending.prefix(2).joined(separator: " · ")
            let tail = pending.count > 2 ? AppLocalized(" and more") : ""
            return String(format: AppLocalized("Verifying %@%@ · %lds elapsed"), head, tail, Int(elapsed))
        }
        return String(format: AppLocalized("Finished in %lds · %ld passed"), Int(elapsed), passedCount)
    }

    func run(force: Bool = true) async {
        guard !running else { return }
        running = true
        finishedAt = nil
        elapsed = 0
        let started = Date()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                await MainActor.run { self.elapsed = Date().timeIntervalSince(started) }
            }
        }
        defer {
            timerTask?.cancel()
            timerTask = nil
            running = false
            finishedAt = Date()
        }

        for index in basic.indices { basic[index].status = .pending; basic[index].detail = "" }
        for index in project.indices { project[index].status = .pending; project[index].detail = "" }
        for index in optional.indices { optional[index].status = .pending; optional[index].detail = "" }

        // 1) 沙箱内核
        set("kernel", .running)
        let booted = ISHKernel.shared.isBooted
        set("kernel", booted ? .ok : .failed(AppLocalized("The iSH kernel is not running")),
            detail: booted ? AppLocalized("Kernel booted") : AppLocalized("Open a chat once to boot the sandbox"))

        // 2) 命令执行
        set("shell", .running)
        let shellResult = await guest("printf MINIS_DIAG_OK", timeout: 12)
        if shellResult.contains("MINIS_DIAG_OK") {
            set("shell", .ok, detail: AppLocalized("Command returned normally"))
        } else {
            set("shell", .failed(AppLocalized("The sandbox did not answer")), detail: firstLine(shellResult))
        }

        // 3) 实时工具通道
        set("bridge", .running)
        let stubs = await guest("ls /usr/local/bin | wc -l", timeout: 12).trimmingCharacters(in: .whitespacesAndNewlines)
        if let count = Int(stubs), count > 0 {
            set("bridge", .ok, detail: String(format: AppLocalized("%ld native commands available"), count))
        } else {
            set("bridge", .failed(AppLocalized("No native offload command was found")), detail: firstLine(stubs))
        }

        // 4) 运行配置
        set("config", .running)
        let providers = ProviderConfigStore.shared.instances.count
        if providers > 0 {
            set("config", .ok, detail: String(format: AppLocalized("%ld provider configurations loaded"), providers))
        } else {
            set("config", .skipped(AppLocalized("No provider configured yet")), detail: "")
        }

        // 5) 项目文件
        set("files", .running)
        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("minis-diag-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try fm.removeItem(at: probe)
            set("files", .ok, detail: AppLocalized("Workspace is writable"))
        } catch {
            set("files", .failed(AppLocalized("Workspace is not writable")), detail: error.localizedDescription)
        }

        // 6) Git & 常用工具
        set("git", .running)
        let git = await guest("git --version 2>&1 | head -1", timeout: 12).trimmingCharacters(in: .whitespacesAndNewlines)
        if git.lowercased().contains("git version") {
            set("git", .ok, detail: git)
        } else {
            set("git", .failed(AppLocalized("git is not available in the sandbox")), detail: firstLine(git))
        }

        // 7) 代码辅助
        set("search", .running)
        let rg = await guest("rg --version 2>&1 | head -1", timeout: 12).trimmingCharacters(in: .whitespacesAndNewlines)
        if rg.lowercased().contains("ripgrep") {
            set("search", .ok, detail: rg)
        } else {
            set("search", .skipped(AppLocalized("ripgrep is not installed")), detail: firstLine(rg))
        }

        // 8) 手机编译
        set("build", .running)
        let host = MinisHostEnvironmentDetector.detect()
        let health = await NativeRuntimeHealthMonitor.shared.refresh(force: force)
        if health.ok {
            set("build", .ok, detail: health.summary)
        } else {
            set("build", .failed(health.failure.title), detail: health.summary)
        }

        // 9) 运行时完整性
        set("integrity", .running)
        if let summary = RuntimeIntegrity.summary(theosRoot: health.theosRoot) {
            set("integrity", .failed(AppLocalized("Runtime files are incomplete (zsh / libiosexec)")), detail: summary)
        } else if health.theosRoot == nil {
            set("integrity", .skipped(AppLocalized("No runtime installed")), detail: "")
        } else {
            set("integrity", .ok, detail: AppLocalized("zsh · libiosexec · make are present"))
        }

        // 10) 环境识别
        set("environment", .running)
        set("environment", host.environment.canRunNativeBinaries ? .ok : .skipped(host.summary),
            detail: host.nativeOutlook)
    }

    private func set(_ id: String, _ status: RuntimeDiagItem.Status, detail: String = "") {
        for index in basic.indices where basic[index].id == id {
            basic[index].status = status; basic[index].detail = detail; return
        }
        for index in project.indices where project[index].id == id {
            project[index].status = status; project[index].detail = detail; return
        }
        for index in optional.indices where optional[index].id == id {
            optional[index].status = status; optional[index].detail = detail; return
        }
    }

    /// 在 guest 里跑一条命令，返回 stdout+stderr。
    private func guest(_ command: String, timeout: TimeInterval) async -> String {
        do {
            let result = try await ISHExecutionCoordinator.shared.execute(
                sessionId: "runtime-diagnostics",
                command: command,
                timeout: timeout,
                lineCallback: { _ in },
                pidCallback: { _ in })
            return result.output
        } catch {
            return error.localizedDescription
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}

// MARK: - 页面

struct RuntimeDiagnosticsView: View {

    @StateObject private var model = RuntimeDiagnosticsModel()
    @ObservedObject private var manager = DeveloperRuntimeManager.shared
    @ObservedObject private var preference = ToolExecutorPreference.shared
    @ObservedObject private var healthMonitor = NativeRuntimeHealthMonitor.shared

    @State private var manualRoot = NativeToolchain.manualRootPath ?? ""
    @State private var repairing = false
    @State private var repairReport: RuntimeRepairReport?
    @State private var showDetails = false
    @State private var manifestURLText = RuntimeManifestLoader.overrideURLString

    var body: some View {
        List {
            statusSection
            groupSection(AppLocalized("Basics"), items: model.basic)
            groupSection(AppLocalized("Project tools"), items: model.project)
            groupSection(AppLocalized("Optional capabilities"), items: model.optional)
            repairSection
            detailsSection
            settingsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: "运行诊断"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await model.run(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.running)
            }
        }
        .task {
            await model.run(force: true)
            await manager.loadManifestIfNeeded()
        }
    }

    // MARK: 顶部总状态

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: model.overallTitle)
                        .font(.headline)
                    Text(verbatim: model.overallSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if model.running {
                    ProgressView()
                } else if model.failedCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(verbatim: "状态")
        }
    }

    // MARK: 分组

    private func groupSection(_ title: String, items: [RuntimeDiagItem]) -> some View {
        Section {
            ForEach(items) { item in
                diagRow(item)
            }
        } header: {
            Text(verbatim: title)
        }
    }

    private func diagRow(_ item: RuntimeDiagItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: item.tint,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.body.weight(.semibold))
                Text(verbatim: subtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            trailing(for: item)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for item: RuntimeDiagItem) -> String {
        switch item.status {
        case .pending:
            return item.subtitle
        case .running:
            return AppLocalized("Checking…") + " · " + item.subtitle
        case .ok:
            return item.detail.isEmpty ? AppLocalized("Passed") : item.detail
        case .failed(let reason):
            return item.detail.isEmpty ? reason : reason + " · " + item.detail
        case .skipped(let reason):
            return item.detail.isEmpty ? reason : reason + " · " + item.detail
        }
    }

    @ViewBuilder
    private func trailing(for item: RuntimeDiagItem) -> some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running:
            ProgressView()
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    // MARK: 一键修复

    private var repairSection: some View {
        Section {
            Button {
                repairing = true
                Task {
                    let report = await RuntimeRepair.oneClick()
                    repairReport = report
                    repairing = false
                    await model.run(force: true)
                    await healthMonitor.refresh(force: true)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(AppLocalized("One-tap repair"))
                    Spacer()
                    if repairing { ProgressView() }
                }
            }
            .disabled(repairing)

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
            Text(verbatim: "修复")
        } footer: {
            Text(verbatim: "清缓存 → 重新探针 → 按失败类型处理：zsh / libiosexec 不完整会重装运行时；无法原生执行时自动切回 iSH 沙箱。")
        }
    }

    // MARK: 详细信息（工具链逐项）

    private var detailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showDetails) {
                let diag = NativeToolchain.shared.diagnostics()
                ForEach(Array(diag.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(line.ok ? Color.green : Color.orange)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: line.title).font(.caption.weight(.medium))
                            Text(verbatim: line.detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                let host = MinisHostEnvironmentDetector.detect()
                ForEach(Array(host.evidence.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                TextField("Theos root path", text: $manualRoot)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Button("Apply and re-detect") {
                        NativeToolchain.manualRootPath = manualRoot
                        manualRoot = NativeToolchain.manualRootPath ?? ""
                        Task { await model.run(force: true) }
                    }
                    .disabled(manualRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear", role: .destructive) {
                        manualRoot = ""
                        NativeToolchain.manualRootPath = nil
                        Task { await model.run(force: true) }
                    }
                }
                .font(.footnote)
            } label: {
                Label(AppLocalized("Toolchain details"), systemImage: "stethoscope")
            }
        } footer: {
            Text(verbatim: "Shell 一行显示实际会用哪个 shell；若是「未找到」，编译一定失败。")
        }
    }

    // MARK: 运行时清单 / 执行器

    private var settingsSection: some View {
        Section {
            LabeledContent(AppLocalized("Effective executor"), value: preference.resolvedExecutor.displayName)
            if let health = healthMonitor.health {
                LabeledContent(AppLocalized("Runtime probe"), value: health.summary)
                    .font(.caption)
            }
            TextField("Runtime manifest URL", text: $manifestURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 10, design: .monospaced))
            HStack {
                Button("Apply manifest URL") {
                    RuntimeManifestLoader.setOverrideURL(manifestURLText)
                    manifestURLText = RuntimeManifestLoader.overrideURLString
                    Task { await manager.refreshManifest() }
                }
                .disabled(manifestURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Reset", role: .destructive) {
                    manifestURLText = ""
                    RuntimeManifestLoader.setOverrideURL("")
                    Task { await manager.refreshManifest() }
                }
            }
            .font(.footnote)
            if let error = manager.manifestError {
                Text(verbatim: error).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(manager.runtimes) { descriptor in
                let state = manager.state(for: descriptor)
                HStack {
                    Text(verbatim: descriptor.displayName)
                    Spacer()
                    Text(verbatim: state.isInstalled ? (state.record?.version ?? AppLocalized("Installed"))
                                                     : AppLocalized("Not installed"))
                        .foregroundStyle(state.isInstalled ? Color.secondary : Color.orange)
                        .font(.caption)
                }
            }
            Button {
                Task { await manager.refreshManifest() }
            } label: {
                Label("Refresh manifest", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.isLoadingManifest)
        } header: {
            Text(verbatim: "运行时与执行器")
        } footer: {
            Text(verbatim: "默认来源：JiuJiuyu77/CodexApp-Runtime。安装/更新/移除在 设置 → Developer Runtime 里操作。")
        }
    }
}
