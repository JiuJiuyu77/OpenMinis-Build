import Foundation
import SwiftUI

/// 一份「模型编译配置」：模型调用 `native_build(profile:)` 时使用的参数默认值。
///
/// [T-model-config-independent] 这份配置与编译工作台里用户当前填的设置**完全独立**：
/// - 工作台读写的只有 `NativeBuildService` 自己的状态，用户怎么调都行；
/// - 这份配置只被 `native_build` 读取，套用不会回写工作台，工作台改动也不会
///   影响这里。
/// 之前 `apply()` 直接往 `NativeBuildService.shared` 写，导致模型一编译就把用户
/// 正在调的界面参数改掉——那是耦合，不是便利。
struct BuildProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var scheme: String
    var archs: String
    var obfuscation: BuildObfuscation
    var makeMode: NativeMakeMode
    var stripSymbols: Bool
    var hideSymbols: Bool
    var encryptStrings: Bool
    var cleanBeforeBuild: Bool
    var packageOnly: Bool
    var incremental: Bool
    var jobs: Int
    var extraFlags: String
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         scheme: String = "rootless",
         archs: String = "arm64",
         obfuscation: BuildObfuscation = .off,
         makeMode: NativeMakeMode = .project,
         stripSymbols: Bool = false,
         hideSymbols: Bool = false,
         encryptStrings: Bool = false,
         cleanBeforeBuild: Bool = false,
         packageOnly: Bool = false,
         incremental: Bool = true,
         jobs: Int = 4,
         extraFlags: String = "",
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.archs = archs
        self.obfuscation = obfuscation
        self.makeMode = makeMode
        self.stripSymbols = stripSymbols
        self.hideSymbols = hideSymbols
        self.encryptStrings = encryptStrings
        self.cleanBeforeBuild = cleanBeforeBuild
        self.packageOnly = packageOnly
        self.incremental = incremental
        self.jobs = jobs
        self.extraFlags = extraFlags
        self.createdAt = createdAt
    }

    var summary: String {
        var parts: [String] = [obfuscation.rawValue, makeMode.rawValue]
        if stripSymbols { parts.append("strip") }
        if hideSymbols { parts.append("hidden") }
        if encryptStrings { parts.append("sobf") }
        parts.append(packageOnly ? "pack-only" : "build")
        if incremental { parts.append("incr") }
        return parts.joined(separator: " · ")
    }
}

/// 模型侧配置的存储。与工作台的 `NativeBuildService` 没有任何写入关系。
@MainActor
final class BuildProfileStore: ObservableObject {
    static let shared = BuildProfileStore()

    @Published var profiles: [BuildProfile] = []

    private let storageKey = "nativebuild.modelProfiles.v2"

    private init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BuildProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func add(_ profile: BuildProfile) {
        profiles.append(profile)
        persist()
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    func update(_ profile: BuildProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    /// 模型侧按名字取一份配置；找不到就返回 nil（调用方退回显式参数）。
    func profile(named name: String) -> BuildProfile? {
        profiles.first { $0.name == name }
    }
}

/// 设置里的「模型编译配置」页面：独立于编译工作台。
struct ModelBuildProfileSettingsView: View {
    @ObservedObject private var store = BuildProfileStore.shared

    var body: some View {
        Form {
            Section {
                ForEach($store.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(AppLocalized("Name"), text: $profile.name)
                            .font(.headline)
                        HStack {
                            Text(AppLocalized("Obfuscation")).font(.caption)
                            Spacer()
                            Picker("", selection: $profile.obfuscation) {
                                ForEach(BuildObfuscation.allCases) { level in
                                    Text(level.displayName).tag(level)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        HStack {
                            Text(AppLocalized("Build file")).font(.caption)
                            Spacer()
                            Picker("", selection: $profile.makeMode) {
                                ForEach(NativeMakeMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        Toggle(AppLocalized("Strip symbols"), isOn: $profile.stripSymbols)
                            .font(.caption)
                        Toggle(AppLocalized("Hide symbols"), isOn: $profile.hideSymbols)
                            .font(.caption)
                        Toggle(AppLocalized("Encrypt strings"), isOn: $profile.encryptStrings)
                            .font(.caption)
                        Button(role: .destructive) {
                            store.remove(profile.id)
                        } label: {
                            Label(AppLocalized("Delete this profile"), systemImage: "trash")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                    // onChange(of:initial:_:) 需要 iOS 17，这里用兼容写法（部署目标是 16）。
                    .onChange(of: profile) { newValue in
                        store.update(newValue)
                    }
                }
                Button {
                    store.add(BuildProfile(name: AppLocalized("Profile") + " \(store.profiles.count + 1)"))
                } label: {
                    Label(AppLocalized("New build profile"), systemImage: "plus.circle.fill")
                }
            } header: {
                Text(AppLocalized("Model build profiles"))
            } footer: {
                Text(AppLocalized("These are used only when the model calls native_build with profile=<name>. They never change what you have set in the build workbench, and the workbench never changes these."))
            }
        }
        .navigationTitle(AppLocalized("Model build profiles"))
    }
}
