//
//  BuildWorkbenchView.swift
//  Minis — 编译工作台界面（设置 › Agent 工具 › 编译工作台）
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BuildWorkbenchView: View {

    @StateObject private var service = NativeBuildService.shared
    @ObservedObject private var profileStore = BuildProfileStore.shared
    @State private var showPicker = false
    @State private var showArchivePicker = false
    @State private var showIPAPicker = false
    @State private var importMessage: String?
    @State private var importing = false

    var body: some View {
        Form {
            toolchainNotice
            buildProfileSection
            projectSection
            productSection
            configSection
            protectionSection
            obfuscationSection
            customFlagsSection
            actionSection
            if !service.logLines.isEmpty { logSection }
            if let result = service.lastResult, !result.artifacts.isEmpty { artifactSection(result) }
        }
        .navigationTitle(Text(verbatim: "编译工作台"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            FolderPickerView { url in
                _ = url.startAccessingSecurityScopedResource()
                service.projectPath = url.path
                service.persist()
            }
        }
        .sheet(isPresented: $showArchivePicker) {
            ArchivePickerView { url in
                importArchive(url)
            }
        }
        .sheet(isPresented: $showIPAPicker) {
            ArchivePickerView(contentTypes: [.zip], allowIPA: true) { url in
                if let dest = copyIPAPersistently(url) {
                    service.shellSourceIPA = dest.path
                    service.persist()
                }
            }
        }
    }

    // MARK: - 工具链（已搬走，只留一行状态）

    /// [T-workbench-toolchain-moved] 工具链的检测、逐项诊断、手动指定根目录
    /// 原本都在这个工作台里，和「编译工程」混在一屏；它们其实是运行时问题，
    /// 现在统一放在 设置 → Agent Runtime → 运行时诊断（RuntimeDiagnosticsView）。
    /// 工作台只在不可用时给一个入口，就绪时完全不占地方。
    @ViewBuilder
    private var toolchainNotice: some View {
        if !service.toolchainReady {
            Section {
                NavigationLink {
                    RuntimeDiagnosticsView()
                } label: {
                    Label(AppLocalized("Native toolchain not found — open Runtime diagnostics"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(AppLocalized("Toolchain detection, per-item diagnostics and the manual Theos root all live in Settings → Agent Runtime → Runtime diagnostics. Re-run detection there; this workbench no longer carries a second copy."))
            }
        }
    }

    // MARK: - 编译配置

    /// 配置 = 工程参数 + 混淆强度 + 保护/输出开关的快照，换项目/换模型时一键套用。
    private var buildProfileSection: some View {
        Section {
            ForEach(profileStore.profiles) { profile in
                Button {
                    profileStore.apply(profile)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: profile.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(verbatim: profile.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profileStore.matchesCurrentSettings(profile) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        profileStore.remove(profile.id)
                    } label: {
                        Label(AppLocalized("Delete"), systemImage: "trash")
                    }
                }
            }
            Button {
                profileStore.saveCurrent(named: nextProfileName())
            } label: {
                Label(AppLocalized("Save current settings as a profile"),
                      systemImage: "square.and.arrow.down")
            }
        } header: {
            Text(AppLocalized("Build profiles"))
        } footer: {
            Text(AppLocalized("A profile snapshots scheme, archs, obfuscation strength, protection and output switches. Project path is deliberately not part of it."))
        }
    }

    private func nextProfileName() -> String {
        "\(AppLocalized("Profile")) \(profileStore.profiles.count + 1)"
    }

    // MARK: - 工程

    private var projectSection: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.projectPath.isEmpty ? "选择工程目录…" : (service.projectPath as NSString).lastPathComponent)
                            .foregroundStyle(service.projectPath.isEmpty ? Color.accentColor : .primary)
                        if !service.projectPath.isEmpty {
                            Text("\(NativeToolchain.shared.detectKind(service.projectPath).rawValue) · \(service.projectPath)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "folder")
                }
            }
            Button {
                showArchivePicker = true
            } label: {
                Label(importing ? "正在导入…" : "上传工程压缩包（zip / tar.gz）", systemImage: "square.and.arrow.down")
            }
            .disabled(importing)
            if let importMessage {
                Text(verbatim: importMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            let imported = ProjectImporter.importedProjects()
            if !imported.isEmpty {
                Menu {
                    ForEach(imported.prefix(12), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            service.projectPath = url.path
                            service.persist()
                        }
                    }
                } label: {
                    Label("从已导入的工程中选择", systemImage: "clock.arrow.circlepath")
                }
            }
        } header: {
            Text(verbatim: "工程")
        } footer: {
            Text(verbatim: "可以直接选择设备上的工程目录，也可以上传 zip / tar.gz 由 App 解包。导入的项目保存在 Application Support/MinisProjects，不会出现在「我的 iPhone」里。")
        }
    }

    /// 解包上传的工程压缩包并把结果回填。
    private func importArchive(_ url: URL) {
        importing = true
        importMessage = nil
        Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try ProjectImporter.importArchive(url) { line in
                    Task { @MainActor in importMessage = line }
                }
                await MainActor.run {
                    service.projectPath = outcome.projectPath
                    service.persist()
                    importing = false
                    importMessage = "✓ 已导入 \(outcome.topLevel)（\(outcome.fileCount) 个文件）"
                        + (outcome.hadMakefile ? "" : " — 未找到 Makefile，请确认目录")
                }
            } catch {
                await MainActor.run {
                    importing = false
                    importMessage = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    /// 把用户选的 .ipa 复制到持久目录，安全作用域 URL 在回调返回后就失效了。
    private func copyIPAPersistently(_ url: URL) -> URL? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let root = ProjectImporter.importsRoot else { return nil }
        let dir = root.appendingPathComponent("ShellSources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            importMessage = "✗ 复制 ipa 失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 产物类型

    private var productSection: some View {
        Section {
            Picker(selection: Binding(get: { service.product },
                                     set: { service.product = $0; service.persist() })) {
                ForEach(BuildProductKind.allCases) { kind in
                    Text(verbatim: kind.displayName).tag(kind)
                }
            } label: {
                Text(verbatim: "产物类型")
            }
            Text(verbatim: service.product.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if service.product == .ipaShell {
                Button {
                    showIPAPicker = true
                } label: {
                    Label(service.shellSourceIPA.isEmpty
                          ? "选择要打壳的 .ipa"
                          : (service.shellSourceIPA as NSString).lastPathComponent,
                          systemImage: "shippingbox")
                }
                if !service.shellSourceIPA.isEmpty {
                    Text(verbatim: service.shellSourceIPA)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(verbatim: "先把工程编成 .dylib，再注入到 ipa 的主二进制。注入后原签名失效，安装前需要 ldid 重签（TrollStore 会代签）。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(verbatim: "产物")
        }
    }

    // MARK: - 代码保护

    private var protectionSection: some View {
        Section {
            Toggle("增量编译", isOn: Binding(get: { service.incremental },
                                          set: { service.incremental = $0; service.persist() }))
            Toggle("剥离符号（strip -x）", isOn: Binding(get: { service.stripSymbols },
                                                   set: { service.stripSymbols = $0; service.persist() }))
            Toggle("隐藏导出符号（-fvisibility=hidden）", isOn: Binding(get: { service.hideSymbols },
                                                              set: { service.hideSymbols = $0; service.persist() }))
            Toggle("加密字符串常量（OLLVM -sobf）", isOn: Binding(get: { service.encryptStrings },
                                                        set: { service.encryptStrings = $0; service.persist() }))
            if service.encryptStrings && !ollvmAvailable {
                Label {
                    Text(verbatim: "字符串加密需要 OLLVM 运行时；当前未安装，编译会失败。")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
        } header: {
            Text(verbatim: "代码保护")
        } footer: {
            Text(verbatim: "增量编译复用 .theos 中间产物；符号剥离在链接完成后执行。两者都不影响调用签名。")
        }
    }

    // MARK: - 配置

    private var configSection: some View {
        Section {
            Picker("打包方案", selection: Binding(get: { service.scheme },
                                                  set: { service.scheme = $0; service.persist() })) {
                Text(verbatim: "rootless").tag("rootless")
                Text(verbatim: "rootful").tag("rootful")
                Text(verbatim: "roothide").tag("roothide")
            }
            Picker("架构", selection: Binding(get: { service.archs },
                                              set: { service.archs = $0; service.persist() })) {
                Text(verbatim: "arm64").tag("arm64")
                Text(verbatim: "arm64e").tag("arm64e")
                Text(verbatim: "arm64 arm64e").tag("arm64 arm64e")
            }
            Toggle("构建前清理", isOn: Binding(get: { service.cleanBeforeBuild },
                                              set: { service.cleanBeforeBuild = $0; service.persist() }))
            Stepper(value: Binding(get: { service.jobs },
                                   set: { service.jobs = $0; service.persist() }),
                    in: 1...16) {
                Text(verbatim: "并行任务数：\(service.jobs)")
            }
            Toggle("仅打包（不清理）", isOn: Binding(get: { service.packageOnly },
                                                   set: { service.packageOnly = $0; service.persist() }))
            TextField("附加 make 参数", text: Binding(get: { service.extraFlags },
                                                    set: { service.extraFlags = $0; service.persist() }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(verbatim: "构建配置")
        }
    }

    // MARK: - 混淆与自定义编译参数

    private var obfuscationSection: some View {
        Section {
            Picker(selection: Binding(get: { service.obfuscation },
                                     set: { service.obfuscation = $0; service.persist() })) {
                ForEach(BuildObfuscation.allCases) { level in
                    Text(verbatim: level.displayName).tag(level)
                }
            } label: {
                Text(verbatim: "混淆强度")
            }
            if !ollvmAvailable && service.obfuscation.requiresOLLVM {
                Label {
                    Text(verbatim: "当前未安装 OLLVM，选中的强度会导致编译失败。请先在 设置 → Developer Runtime 安装 OLLVM，或改为「关闭」。")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
            Text(verbatim: service.obfuscation.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if service.obfuscation.requiresOLLVM {
                Text(verbatim: "参数：" + service.obfuscation.flagSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text(verbatim: "混淆保护")
        }
    }

    private var customFlagsSection: some View {
        Section {
            TextField("自定义 CFLAGS", text: Binding(get: { service.cflags },
                                                   set: { service.cflags = $0; service.persist() }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 11, design: .monospaced))
            TextField("自定义 LDFLAGS", text: Binding(get: { service.ldflags },
                                                    set: { service.ldflags = $0; service.persist() }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 11, design: .monospaced))
        } header: {
            Text(verbatim: "自定义编译参数")
        } footer: {
            Text(verbatim: "会作为 ADDITIONAL_CFLAGS / ADDITIONAL_LDFLAGS 传给 make，适合加宏定义、搜索路径或链接库。")
        }
    }

    private var ollvmAvailable: Bool { RuntimeCapabilityNames.ollvmInstalled }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            if service.running {
                Button(role: .destructive) {
                    service.cancel()
                } label: {
                    Label("终止构建", systemImage: "stop.fill")
                }
            } else {
                Button {
                    service.startBuild()
                } label: {
                    Label("构建 DEB", systemImage: "hammer.fill")
                }
                .disabled(service.projectPath.isEmpty || !service.toolchainReady)
            }
            if let result = service.lastResult {
                Text(result.ok ? "上次构建成功 · \(String(format: "%.1f", result.seconds)) 秒"
                                : "上次构建失败（退出码 \(result.exitCode)）")
                    .font(.caption)
                    .foregroundStyle(result.ok ? Color.green : Color.red)
            }
        } header: {
            Text(verbatim: "构建")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(service.logLines.enumerated()), id: \.offset) { index, line in
                            Text(verbatim: line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 220)
                .onChange(of: service.logLines.count) { newValue in
                    if newValue > 0 { proxy.scrollTo(newValue - 1, anchor: .bottom) }
                }
            }
        } header: {
            HStack {
                Text(verbatim: "日志")
                Spacer()
                Text(verbatim: "\(service.logLines.count) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 产物

    private func artifactSection(_ result: NativeBuildResult) -> some View {
        Section {
            ForEach(result.artifacts, id: \.self) { path in
                ShareLink(item: URL(fileURLWithPath: path)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: (path as NSString).lastPathComponent)
                            Text(verbatim: path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } header: {
            Text(verbatim: "产物")
        }
    }
}

// MARK: - 目录选择器

struct FolderPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - 压缩包 / ipa 选择器

struct ArchivePickerView: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.zip, .gzip, .archive, .data]
    var allowIPA: Bool = false
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types = contentTypes
        if allowIPA { types.append(.zip) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - 设置页入口

#endif
