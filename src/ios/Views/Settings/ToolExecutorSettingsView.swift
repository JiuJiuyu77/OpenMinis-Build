import SwiftUI

/// Settings → 执行器（Executor）。
///
/// 三个开关：
///   1. 默认执行器：自动 / 沙箱（iSH）/ 原生 Runtime
///   2. 优先使用自定义 Runtime（Developer Runtime 装的那份工具链）
///   3. 沙箱模式（强制只走 iSH，等价于关闭一切原生执行）
///
/// 外加「能力」只读区块：直接问 CapabilityRegistry，展示每项能力当前是否
/// 可用以及不可用的原因——避免设置页说“已安装”、实际调用却失败。
struct ToolExecutorSettingsView: View {

    @ObservedObject private var preference = ToolExecutorPreference.shared
    @ObservedObject private var capabilities = CapabilityRegistry.shared
    @ObservedObject private var plugins = PluginManifestStore.shared
    @ObservedObject private var healthMonitor = NativeRuntimeHealthMonitor.shared
    @State private var manualRoot = NativeToolchain.manualRootPath ?? ""
    @State private var showDiagnostics = false
    @State private var repairing = false
    @State private var repairReport: RuntimeRepairReport?

    var body: some View {
        Form {
            Section {
                Picker("Default executor", selection: $preference.mode) {
                    ForEach(ToolExecutorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Default executor")
            } footer: {
                Text(preference.mode.explanation)
            }

            Section {
                Toggle(isOn: $preference.sandboxMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sandbox mode")
                        Text("Keep every command inside the iSH Alpine sandbox.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $preference.preferCustomRuntime) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prefer custom runtime")
                        Text("Use the toolchain installed from Developer Runtime instead of the shared copy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(preference.sandboxMode)
            } header: {
                Text("Native execution")
            } footer: {
                Text("Sandbox mode overrides the executor choice. Native execution needs TrollStore or a jailbreak; in an App Store build everything falls back to iSH.")
            }

            environmentSection
            repairSection

            Section {
                LabeledContent("Effective executor", value: preference.resolvedExecutor.displayName)
                if preference.sandboxMode {
                    Label("Sandbox mode is on — native execution is disabled.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }

            toolchainSection

            Section {
                ForEach(capabilities.report(), id: \.id) { status in
                    CapabilityRow(status: status)
                }
            } header: {
                HStack {
                    Text("Capabilities")
                    Spacer()
                    Button {
                        capabilities.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Refresh"))
                }
            } footer: {
                Text("Capabilities come from the app and from installed plugins. A plugin's capabilities disappear when it is unloaded.")
            }

            pluginSection
        }
        .navigationTitle("Executor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await healthMonitor.refresh() }
            capabilities.registerBuiltinsIfNeeded()
            plugins.installBundledExamplesIfNeeded()
            plugins.reload()
        }
    }

    // MARK: - 环境识别

    /// 一行说清「这台设备能不能原生执行」。放在执行器选择旁边，因为
    /// 「自动」到底会不会切到原生，取决于这里。
    private var environmentSection: some View {
        Section {
            let host = MinisHostEnvironmentDetector.detect()
            LabeledContent(AppLocalized("Host environment"), value: host.summary)
            let health = healthMonitor.health
            LabeledContent(AppLocalized("Runtime probe"),
                           value: healthMonitor.checking
                               ? AppLocalized("Checking…")
                               : (health?.ok == true ? AppLocalized("Ready") : (health?.failure.title ?? AppLocalized("Not checked yet"))))
            Text(RuntimeRepair.environmentVerdict(host, health: health))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(AppLocalized("Environment"))
        } footer: {
            Text(AppLocalized("TrollStore and jailbroken installs can run the native toolchain. A sandboxed build cannot load its libraries (libiosexec) — commands then stay in the iSH sandbox, which is expected."))
        }
    }

    // MARK: - 一键修复

    private var repairSection: some View {
        Section {
            Button {
                repairing = true
                Task {
                    repairReport = await RuntimeRepair.oneClick()
                    repairing = false
                    capabilities.refresh()
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
            Text(AppLocalized("Repair"))
        } footer: {
            Text(AppLocalized("Clears the cached probe, runs the runtime shell once, and applies the matching fix: a sandbox-blocked runtime is routed to iSH, a missing runtime is reported with the install path."))
        }
    }

    // MARK: - 工具链（含手动修复）

    /// 「找不到原生工具链」的唯一手动修复入口：不必重装、不必换设备布局，
    /// 把真实的 Theos 根目录填进来立即生效。
    private var toolchainSection: some View {
        Section {
            let diag = NativeToolchain.shared.diagnostics()
            LabeledContent("Toolchain",
                           value: diag.usable ? AppLocalized("Ready") : AppLocalized("Not found"))
            DisclosureGroup(isExpanded: $showDiagnostics) {
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
            } label: {
                Label("Toolchain diagnostics", systemImage: "stethoscope")
            }
            TextField("Theos root path", text: $manualRoot)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button("Apply and re-detect") {
                    NativeToolchain.manualRootPath = manualRoot
                    manualRoot = NativeToolchain.manualRootPath ?? ""
                    capabilities.refresh()
                }
                .disabled(manualRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Clear", role: .destructive) {
                    manualRoot = ""
                    NativeToolchain.manualRootPath = nil
                    capabilities.refresh()
                }
            }
            .font(.footnote)
        } header: {
            Text("Toolchain")
        } footer: {
            Text("If the app cannot find Theos on its own, paste the directory that contains makefiles/common.mk (or its parent). The path is remembered and used first on every later launch.")
        }
    }

    // MARK: - 插件（能力来源）

    private var pluginSection: some View {
        Section {
            if plugins.manifests.isEmpty {
                Text("No plugins found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plugins.manifests) { manifest in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: manifest.displayName)
                            Spacer()
                            Text(verbatim: manifest.isEnabled
                                 ? AppLocalized("Enabled")
                                 : AppLocalized("Disabled"))
                                .font(.caption2)
                                .foregroundStyle(manifest.isEnabled ? Color.green : .secondary)
                        }
                        Text(verbatim: "\(manifest.id) · \((manifest.capabilities ?? []).count) " + AppLocalized("capabilities"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                plugins.reload()
                capabilities.refresh()
            } label: {
                Label("Rescan plugins", systemImage: "arrow.triangle.2.circlepath")
            }
            if let error = plugins.lastError {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Plugins")
        } footer: {
            Text("A plugin declares capabilities in MinisConfig/plugins/<id>/manifest.json. A disabled plugin's capabilities are removed from the list above.")
        }
    }
}

private struct CapabilityRow: View {
    let status: CapabilityStatus

    private var symbol: String {
        switch status.state {
        case .available: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status.state {
        case .available: return .green
        case .blocked: return .orange
        case .unavailable: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                if let reason = status.reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 优先用内建能力的人类可读名；插件能力回落到 id。
    /// `@MainActor`：`CapabilityRegistry` 是主线程隔离的，`body` 也在主线程，
    /// 但计算属性本身默认 nonisolated，直接调用会触发 Swift 6 的并发诊断。
    @MainActor
    private var displayName: String {
        CapabilityRegistry.shared.descriptor(for: status.id)?.displayName ?? status.id
    }
}
