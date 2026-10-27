import SwiftUI

/// Settings → Developer Runtime.
///
/// Lists the runtimes published by the developer runtime manifest (Theos,
/// OLLVM, ReverseTools, …) and drives download / verify / extract / remove.
/// Purely a toolchain installer: no chat, model or agent configuration lives
/// here, and nothing on this screen touches the AI layer.
struct DeveloperRuntimeSettingsView: View {
    @ObservedObject private var manager = DeveloperRuntimeManager.shared

    /// One alert for both flows: two `.alert(item:)` modifiers on the same view
    /// conflict, and the second silently replaces the first.
    @State private var pendingConfirm: ConfirmAction?
    @State private var codexOptions: [RuntimeVersionCatalog.Option] = []
    @State private var loadingCodexVersions = false
    @State private var codexVersionError: String?

    private enum ConfirmAction: Identifiable {
        case install(RuntimeDescriptor)
        case remove(RuntimeDescriptor)

        var id: String {
            switch self {
            case .install(let descriptor): return "install-\(descriptor.id)"
            case .remove(let descriptor): return "remove-\(descriptor.id)"
            }
        }
    }

    var body: some View {
        Form {
            if let message = manager.manifestError, manager.manifest == nil {
                Section {
                    Label {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Button {
                        Task { await manager.refreshManifest() }
                    } label: {
                        if manager.isLoadingManifest {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Refreshing…")
                            }
                        } else {
                            Text("Retry")
                        }
                    }
                    .disabled(manager.isLoadingManifest)
                } footer: {
                    Text("The manifest lists the developer toolchains this build can install. A cached copy is used when the network is unavailable.")
                }
            }

            ForEach(groupedRuntimes, id: \.group) { section in
                Section {
                    ForEach(section.runtimes) { descriptor in
                        RuntimeRow(
                            descriptor: descriptor,
                            state: manager.state(for: descriptor),
                            operation: manager.operation(for: descriptor.id),
                            error: manager.error(for: descriptor.id),
                            missingRequirements: manager.missingRequirements(for: descriptor),
                            onInstall: { pendingConfirm = .install(descriptor) },
                            onRemove: { pendingConfirm = .remove(descriptor) },
                            onCancel: { manager.cancel(descriptor.id) })
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer {
                        Text(footer)
                    }
                }
            }

            if let codex = manager.runtimes.first(where: { $0.handler == "codex" }) {
                codexVersionSection(codex)
            }

            Section {
                LabeledContent("Storage", value: DeveloperRuntimeManager.format(installedBytes))
            } footer: {
                Text("Runtimes are stored in the app's Application Support directory and are removed when the app is deleted.\nOnly verified archives are extracted. A failed or cancelled install removes its temporary download.")
            }

            if let theos = manager.runtimes.first(where: {
                ($0.provides ?? []).contains("ios.toolchain")
            }), manager.state(for: theos).isInstalled {
                theosSection(theos)
            }
        }
        .navigationTitle("Developer Runtime")
        .navigationBarTitleDisplayMode(.inline)
        .task { await manager.loadManifestIfNeeded() }
        .refreshable { await manager.refreshManifest() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await manager.refreshManifest() }
                } label: {
                    if manager.isLoadingManifest {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(manager.isLoadingManifest)
                .accessibilityLabel(Text("Refresh"))
            }
        }
        .alert(item: $pendingConfirm) { action in
            switch action {
            case .install(let descriptor):
                return Alert(
                    title: Text(String(format: AppLocalized("Install %@?"), descriptor.displayName)),
                    message: Text(installMessage(descriptor)),
                    primaryButton: .default(Text("Install")) {
                        manager.install(descriptor)
                    },
                    secondaryButton: .cancel(Text("Cancel")))
            case .remove(let descriptor):
                let size = manager.state(for: descriptor).record?.sizeBytes ?? 0
                return Alert(
                    title: Text(String(format: AppLocalized("Remove %@?"), descriptor.displayName)),
                    message: Text(String(
                        format: AppLocalized("Its files (%@) will be deleted from this iPhone. You can install it again from this screen."),
                        DeveloperRuntimeManager.format(size))),
                    primaryButton: .destructive(Text("Remove")) {
                        manager.remove(descriptor.id)
                    },
                    secondaryButton: .cancel(Text("Cancel")))
            }
        }
    }

    // MARK: - Sections

    private struct RuntimeSection: Identifiable {
        let group: String
        let title: String
        let runtimes: [RuntimeDescriptor]
        let footer: String?
        var id: String { group }
    }

    private var groupedRuntimes: [RuntimeSection] {
        let ordered = manager.runtimes
        var sections: [RuntimeSection] = []
        for descriptor in ordered {
            let group = descriptor.group ?? "other"
            if let index = sections.firstIndex(where: { $0.group == group }) {
                sections[index] = RuntimeSection(
                    group: group,
                    title: sections[index].title,
                    runtimes: sections[index].runtimes + [descriptor],
                    footer: sections[index].footer)
            } else {
                sections.append(RuntimeSection(
                    group: group,
                    title: Self.sectionTitle(for: group),
                    runtimes: [descriptor],
                    footer: Self.sectionFooter(for: group)))
            }
        }
        return sections
    }

    private static func sectionTitle(for group: String) -> String {
        switch group {
        case "compiler": return AppLocalized("Compiler")
        case "core": return AppLocalized("Core")
        case "tools": return AppLocalized("Tools")
        default: return AppLocalized("Other")
        }
    }

    private static func sectionFooter(for group: String) -> String? {
        switch group {
        case "compiler":
            return AppLocalized("The iOS toolchain: clang, the iPhoneOS SDK, the linker, ldid and DEB packaging. Other runtimes depend on it.")
        case "tools":
            return AppLocalized("Optional runtimes used by the developer tools. Install only what you need; each one is downloaded on demand.")
        default:
            return nil
        }
    }

    // MARK: - Codex 可选版本

    /// 清单只发布最新版；这里从 GitHub Releases 拉历史版本，允许装旧版。
    private func codexVersionSection(_ descriptor: RuntimeDescriptor) -> some View {
        Section {
            LabeledContent(AppLocalized("Installed version"),
                           value: manager.state(for: descriptor).record?.version ?? AppLocalized("Not installed"))
            if loadingCodexVersions {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(AppLocalized("Loading versions…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if codexOptions.isEmpty {
                Button {
                    Task { await loadCodexVersions() }
                } label: {
                    Label(AppLocalized("Load available versions"), systemImage: "arrow.clockwise")
                }
            } else {
                Menu {
                    ForEach(codexOptions) { option in
                        Button(versionTitle(option)) {
                            installCodex(option, from: descriptor)
                        }
                    }
                } label: {
                    Label(AppLocalized("Install another version"), systemImage: "arrow.down.circle")
                }
            }
            if let codexVersionError {
                Text(verbatim: codexVersionError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !codexOptions.isEmpty {
                Button(AppLocalized("Refresh version list")) {
                    Task { await loadCodexVersions(force: true) }
                }
                .font(.footnote)
            }
        } header: {
            Text(AppLocalized("Codex versions"))
        } footer: {
            Text(AppLocalized("Versions come from the runtime repository's GitHub releases. Installing one replaces the current Codex runtime only — the rest of the toolchain is untouched."))
        }
    }

    private func loadCodexVersions(force: Bool = false) async {
        if loadingCodexVersions { return }
        if !force, !codexOptions.isEmpty { return }
        loadingCodexVersions = true
        codexVersionError = nil
        let options = await RuntimeVersionCatalog.versions(handler: "codex")
        codexOptions = options
        if options.isEmpty {
            codexVersionError = AppLocalized("Could not load the release list. Check the network or the runtime repository.")
        }
        loadingCodexVersions = false
    }

    private func installCodex(_ option: RuntimeVersionCatalog.Option, from descriptor: RuntimeDescriptor) {
        let replaced = descriptor.replacingRelease(version: option.version,
                                                   assetName: option.assetName,
                                                   archiveURL: option.archiveURL,
                                                   sha256: option.sha256,
                                                   size: option.size)
        pendingConfirm = .install(replaced)
    }

    private func versionTitle(_ option: RuntimeVersionCatalog.Option) -> String {
        guard let date = option.publishedAt else { return option.version }
        return option.version + " · " + date.formatted(date: .abbreviated, time: .omitted)
    }

    private var installedBytes: Int64 {
        manager.records.values.reduce(0) { $0 + $1.sizeBytes }
    }

    @ViewBuilder
    private func theosSection(_ descriptor: RuntimeDescriptor) -> some View {
        let root = DeveloperRuntimePaths.runtimeRoot(id: descriptor.id)
        Section {
            LabeledContent("Root", value: root.path)
            if let sdk = manager.state(for: descriptor).record?.sdk ?? descriptor.sdk {
                LabeledContent("SDK", value: sdk)
            }
            if let path = manager.environment(for: descriptor.id)["PATH"] {
                LabeledContent("PATH", value: path)
            }
            if let report = manager.verification(for: descriptor.id) {
                LabeledContent("Self-check", value: report.shortSummary)
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("This runtime extracts in place. Point THEOS at the Root path and put its usr/bin on PATH for the tool processes that should use it.")
        }
    }

    private func installMessage(_ descriptor: RuntimeDescriptor) -> String {
        var parts: [String] = []
        if descriptor.downloadBytes > 0 {
            parts.append(String(format: AppLocalized("Download: %@"),
                                DeveloperRuntimeManager.format(descriptor.downloadBytes)))
        }
        if descriptor.unpackedBytes > 0 {
            parts.append(String(format: AppLocalized("Installed size: %@"),
                                DeveloperRuntimeManager.format(descriptor.unpackedBytes)))
        }
        parts.append(String(format: AppLocalized("Version: %@"), descriptor.version))
        if let sdk = descriptor.sdk {
            parts.append(String(format: AppLocalized("SDK: %@"), sdk))
        }
        let missing = manager.missingRequirements(for: descriptor)
        if !missing.isEmpty {
            parts.append(String(format: AppLocalized("Needs first: %@"), missing.joined(separator: ", ")))
        }
        if descriptor.archiveFormat == .deb {
            parts.append(AppLocalized("This runtime ships as a Debian package. The installer reads its data member directly."))
            if !ZstdDecompressor.isAvailable {
                parts.append(AppLocalized("No libzstd was found on this device, so a .tar.zst payload cannot be unpacked. Install Theos first — it ships one — then retry."))
            }
        }
        parts.append(AppLocalized("The archive is verified with SHA-256 before it is extracted."))
        return parts.joined(separator: "\n")
    }
}

// MARK: - Row

private struct RuntimeRow: View {
    let descriptor: RuntimeDescriptor
    let state: RuntimeInstallState
    let operation: RuntimeOperation?
    let error: String?
    let missingRequirements: [String]

    let onInstall: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                        .font(.body)
                    if let summary = descriptor.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 8)
                action
            }

            if let operation, operation.isBusy {
                ProgressView(value: operation.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text(operationText(operation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .cancel, action: onCancel) {
                        Text("Cancel")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(operation == .cancelling)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !missingRequirements.isEmpty, operation == nil {
                Text(String(format: AppLocalized("Needs first: %@"),
                            missingRequirements.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: some View {
        Image(systemName: descriptor.ui?.symbol ?? "shippingbox.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch descriptor.ui?.tint {
        case "orange": return .orange
        case "blue": return .blue
        case "green": return .green
        case "teal": return .teal
        case "purple": return .purple
        case "red": return .red
        case "indigo": return .indigo
        case "pink": return .pink
        default: return descriptor.group == "compiler" ? .orange : .indigo
        }
    }

    @ViewBuilder
    private var action: some View {
        if let operation, operation.isBusy || operation == .cancelling {
            ProgressView()
        } else {
            switch state {
            case .notInstalled:
                Button(action: onInstall) {
                    Text("Install")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!missingRequirements.isEmpty || !descriptor.installableArchive)
            case .outdated(let record):
                HStack(spacing: 8) {
                    Button(action: onInstall) {
                        Text("Update")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!missingRequirements.isEmpty || !descriptor.installableArchive)
                    Menu {
                        Text(String(format: AppLocalized("Installed: %@"), record.version))
                        Button(role: .destructive, action: onRemove) {
                            Text("Remove")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("More"))
                }
            case .installed(let record):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Installed"))
                    Menu {
                        Text(String(format: AppLocalized("Installed: %@"), record.version))
                        Text(String(format: AppLocalized("Size: %@"),
                                    DeveloperRuntimeManager.format(record.sizeBytes)))
                        Button(role: .destructive, action: onRemove) {
                            Text("Remove")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("More"))
                }
            }
        }
    }

    private var statusLine: String {
        if !descriptor.installableArchive {
            return AppLocalized("Unsupported archive format")
        }
        switch state {
        case .notInstalled:
            return descriptor.version
        case .installed(let record):
            return String(format: AppLocalized("Installed %@"), record.version)
        case .outdated(let record):
            return String(format: AppLocalized("Update available — installed %@"), record.version)
        }
    }

    private var statusColor: Color {
        switch state {
        case .notInstalled: return .secondary
        case .installed: return .green
        case .outdated: return .orange
        }
    }

    private func operationText(_ operation: RuntimeOperation) -> String {
        switch operation {
        case .downloading(_, let written, let total):
            let done = DeveloperRuntimeManager.format(written)
            let all = total > 0 ? DeveloperRuntimeManager.format(total) : "?"
            return String(format: AppLocalized("Downloading %@ / %@"), done, all)
        case .verifying:
            return AppLocalized("Verifying SHA-256…")
        case .extracting(_, let entries):
            return String(format: AppLocalized("Extracting… (%lld files)"), entries)
        case .finalizing:
            return AppLocalized("Finishing…")
        case .cancelling:
            return AppLocalized("Cancelling…")
        }
    }
}
