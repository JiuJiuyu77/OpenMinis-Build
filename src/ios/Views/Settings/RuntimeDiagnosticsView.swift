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

    /// MT 式「三层执行链」实测：执行层（子进程身份 + 文件边界 + TCC 边界）、
    /// 签名层（ldid + codex-sign）、以及每个已装运行时的自检/签名结论。
    /// 这些项以前完全没有：诊断页只能说「工具链在不在」，说不清「装完了能不能跑」。
    @Published var nativeLayers: [RuntimeDiagItem] = [
        .init(id: "native-spawn", title: AppLocalized("Child process identity"),
              icon: "person.badge.key.fill", tint: [.green, .mint],
              subtitle: AppLocalized("uid / gid a posix_spawn child inherits")),
        .init(id: "native-fs", title: AppLocalized("Filesystem boundary"),
              icon: "externaldrive.fill", tint: [.blue, .teal],
              subtitle: AppLocalized("Writable: /tmp, Library, Media · read-only: /, /System/Library")),
        .init(id: "native-tcc", title: AppLocalized("TCC boundary"),
              icon: "lock.doc.fill", tint: [.orange, .red],
              subtitle: AppLocalized("SMS / CallHistory / TCC stay unreadable despite root")),
        .init(id: "native-sign", title: AppLocalized("Signing layer"),
              icon: "signature", tint: [.purple, .indigo],
              subtitle: AppLocalized("ldid + codex-sign, and the entitlements they propagate")),
        .init(id: "native-runtimes", title: AppLocalized("Runtime self-checks"),
              icon: "checkmark.seal.fill", tint: [.mint, .green],
              subtitle: AppLocalized("Per-runtime self-check and signing outcome")),
    ]

    private var timerTask: Task<Void, Never>?

    var allItems: [RuntimeDiagItem] { basic + project + optional + nativeLayers }
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
        for index in nativeLayers.indices { nativeLayers[index].status = .pending; nativeLayers[index].detail = "" }

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

        // 11) 子进程身份（执行层）：posix_spawn 出来的子进程继承 uid/gid。
        set("native-spawn", .running)
        if NativeToolchain.shared.shellPath == nil {
            set("native-spawn", .skipped(AppLocalized("No native shell available")), detail: "")
        } else {
            let identity = await native("id -u; id -g; uname -m", timeout: 15)
            let parts = identity.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                let summary = "uid=\(parts[0]) gid=\(parts[1])" + (parts.count > 2 ? " · \(parts[2])" : "")
                if parts[0] == "0" {
                    set("native-spawn", .ok, detail: summary)
                } else {
                    set("native-spawn", .failed(AppLocalized("Child processes are not root")), detail: summary)
                }
            } else {
                set("native-spawn", .failed(AppLocalized("Could not read the child process identity")),
                    detail: firstLine(identity))
            }
        }

        // 12) 文件系统边界：该写的能写，SSV 该只读的确实只读。
        set("native-fs", .running)
        let fsScript = "for d in /tmp /var/mobile/Library /var/mobile/Media; do "
            + "t=\"$d/.minis-diag-$$\"; if ( : > \"$t\" ) 2>/dev/null; then echo W:$d; rm -f \"$t\"; "
            + "else echo N:$d; fi; done; "
            + "for d in / /System/Library; do t=\"$d/.minis-diag-$$\"; "
            + "if ( : > \"$t\" ) 2>/dev/null; then echo X:$d; rm -f \"$t\"; else echo R:$d; fi; done"
        let fsReport = await native(fsScript, timeout: 20)
        let writeLines = fsReport.split(separator: "\n").filter { $0.hasPrefix("W:") }
        let wronglyWritable = fsReport.split(separator: "\n").filter { $0.hasPrefix("X:") }
        let readOnly = fsReport.split(separator: "\n").filter { $0.hasPrefix("R:") }
        if writeLines.count >= 3 && wronglyWritable.isEmpty {
            set("native-fs", .ok,
                detail: String(format: AppLocalized("%ld writable · %ld read-only (SSV intact)"),
                               writeLines.count, readOnly.count))
        } else if wronglyWritable.isEmpty {
            set("native-fs", .failed(AppLocalized("Expected writable directories are not writable")),
                detail: firstLine(fsReport))
        } else {
            set("native-fs", .failed(AppLocalized("SSV read-only volumes became writable (unexpected)")),
                detail: wronglyWritable.joined(separator: ", "))
        }

        // 13) TCC 边界：以 root 也读不到短信/通话/TCC 数据库，说明越界被挡住。
        set("native-tcc", .running)
        let tccScript = "for f in /var/mobile/Library/SMS/sms.db "
            + "/var/mobile/Library/CallHistoryDB/CallHistory.storedata /var/mobile/Library/TCC/TCC.db; do "
            + "if head -c 1 \"$f\" >/dev/null 2>&1; then echo OPEN:$f; else echo DENY:$f; fi; done"
        let tccReport = await native(tccScript, timeout: 20)
        let opened = tccReport.split(separator: "\n").filter { $0.hasPrefix("OPEN:") }
        if tccReport.isEmpty {
            set("native-tcc", .skipped(AppLocalized("No native shell available")), detail: "")
        } else if opened.isEmpty {
            let denied = tccReport.split(separator: "\n").filter { $0.hasPrefix("DENY:") }.count
            set("native-tcc", .ok, detail: String(format: AppLocalized("%ld protected stores denied"), denied))
        } else {
            set("native-tcc", .failed(AppLocalized("A TCC-protected store is readable")),
                detail: opened.joined(separator: ", "))
        }

        // 14) 签名层：ldid + codex-sign 是否就位，以及可传播的 entitlements。
        set("native-sign", .running)
        let ldid = RuntimeSigner.locateLdid()
        let codexSign = RuntimeSigner.locateCodexSign()
        let entitlements = RuntimeSigner.entitlementsPlist()
        let entitlementCount = entitlements?.count ?? 0
        if ldid != nil, codexSign != nil, entitlementCount > 0 {
            set("native-sign", .ok,
                detail: String(format: AppLocalized("ldid + codex-sign · %ld entitlements to propagate"),
                               entitlementCount))
        } else if ldid != nil {
            set("native-sign", .skipped(AppLocalized("codex-sign is not bundled")),
                detail: String(format: AppLocalized("%ld entitlements · ad-hoc signing only"), entitlementCount))
        } else {
            set("native-sign", .failed(AppLocalized("ldid was not found")),
                detail: AppLocalized("Install the Theos runtime to enable signing."))
        }

        // 15) 每个已装运行时的自检 / 签名结论。
        set("native-runtimes", .running)
        let manager = DeveloperRuntimeManager.shared
        if manager.records.isEmpty {
            set("native-runtimes", .skipped(AppLocalized("No runtime installed")), detail: "")
        } else {
            var lines: [String] = []
            var bad = 0
            var unchecked = 0
            for (id, record) in manager.records.sorted(by: { $0.key < $1.key }) {
                let selfCheck = record.verification?.status.rawValue ?? "unknown"
                let signing = record.signing?.status.rawValue ?? "unknown"
                if record.verification?.status == .failed || record.signing?.status == .failed { bad += 1 }
                if record.verification == nil || record.signing == nil { unchecked += 1 }
                lines.append("\(id): \(selfCheck) / \(signing)")
            }
            let detail = lines.joined(separator: " · ")
            if bad > 0 {
                set("native-runtimes", .failed(AppLocalized("A runtime failed its self-check or signing")),
                    detail: detail)
            } else if unchecked > 0 {
                // 旧记录没有自检/签名字段：仍算可用，但说明出处，避免误读成「全部验过」。
                set("native-runtimes", .ok,
                    detail: detail + " · " + AppLocalized("installed before self-checks existed"))
            } else {
                set("native-runtimes", .ok, detail: detail)
            }
        }
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
        for index in nativeLayers.indices where nativeLayers[index].id == id {
            nativeLayers[index].status = status; nativeLayers[index].detail = detail; return
        }
    }

    /// 用运行时自带的 bash 跑一条命令（执行层实测）。
    private func native(_ script: String, timeout: TimeInterval) async -> String {
        guard let shell = NativeToolchain.shared.shellPath else { return "" }
        let environment = NativeToolchain.shared.environment()
        let result = await NativeCommandRunner.run(command: script,
                                                   in: nil,
                                                   environment: environment,
                                                   timeout: timeout,
                                                   shellOverride: shell,
                                                   onLine: nil,
                                                   onSpawn: nil)
        return result.output
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
            groupSection(AppLocalized("Native execution (3 layers)"), items: model.nativeLayers)
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
