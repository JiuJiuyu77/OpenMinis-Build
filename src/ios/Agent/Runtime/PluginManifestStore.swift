//
//  PluginManifestStore.swift
//  Minis — 插件清单发现与能力桥接
//
//  插件目录布局（位于 MinisConfig，不进 iOS Files）：
//
//      MinisConfig/plugins/<plugin-id>/manifest.json
//      {
//        "id": "acme.toolbox",
//        "name": "Acme Toolbox",
//        "version": "1.2.0",
//        "enabled": true,
//        "capabilities": [
//          { "id": "plugin.acme.lint", "display_name": "Acme Linter",
//            "kind": "plugin", "requires": ["fs.workspace"],
//            "summary": "Static analysis for Swift sources." }
//        ]
//      }
//
//  这个 store 只做三件事：
//    1. 扫描目录，读出每个插件的 manifest；
//    2. 把声明同步进 `PluginCapabilityBridge`（加载 → 注册，缺失/禁用 → 注销）；
//    3. 供设置页显示“哪些插件的哪些能力正在生效”。
//
//  它**不执行**插件代码，也不下载插件。插件自己的工具怎么跑由插件负责；
//  这里只回答“声明的能力现在算不算数”。
//

import CryptoKit
import Foundation
import Combine

/// 磁盘上的插件清单（`manifest.json`）。
struct PluginManifest: Codable, Equatable, Identifiable {
    let id: String
    let name: String?
    let version: String?
    /// 缺省视为启用；显式 false 表示用户停用。
    let enabled: Bool?
    /// 该插件声明的能力。
    let capabilities: [PluginCapabilityDeclaration]?

    var isEnabled: Bool { enabled ?? true }
    var displayName: String { name ?? id }
}

/// 扫描插件目录并把能力声明同步进能力注册表。
@MainActor
final class PluginManifestStore: ObservableObject {

    static let shared = PluginManifestStore()

    /// 最近一次扫描读到的清单（含被禁用的）。
    @Published private(set) var manifests: [PluginManifest] = []
    /// 扫描失败信息（目录不存在属正常情况，不算失败）。
    @Published private(set) var lastError: String?

    private let fm = FileManager.default
    private weak var bridge: PluginCapabilityBridge?

    init() {}

    /// `plugins` 目录：与 mcp-servers 同级，位于 MinisConfig 下。
    static var pluginsDirectory: URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent("plugins", isDirectory: true)
    }

    /// 绑定能力桥（启动时调用一次）。
    func attach(bridge: PluginCapabilityBridge) {
        self.bridge = bridge
    }

    /// 重新扫描目录并同步能力。幂等，可在设置页刷新或启动时调用。
    func reload() {
        let dir = Self.pluginsDirectory
        lastError = nil

        guard fm.fileExists(atPath: dir.path) else {
            // 没有任何插件目录是正常状态：清空即可，不报错。
            apply(manifests: [])
            return
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: dir,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])
        } catch {
            lastError = error.localizedDescription
            return
        }

        var found: [PluginManifest] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = entry.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                // 目录名与 id 不一致时以 manifest.id 为准，但记录一次日志便于排查。
                found.append(manifest)
            } catch {
                lastError = "\(entry.lastPathComponent): \(error.localizedDescription)"
            }
        }
        apply(manifests: found)
    }

    /// 已启用的插件 id。
    var enabledPluginIDs: [String] {
        manifests.filter(\.isEnabled).map(\.id)
    }

    // MARK: - 内置示例 / OpenAI 桥

    /// 首次运行时写一份**禁用状态**的示例清单，让插件作者看到真实可用的
    /// 字段与 id。禁用的意思很明确：它不会出现在能力列表里，也不会被注册，
    /// 只是磁盘上的模板。用户复制它、改名、改成 enabled 即可。
    func installBundledExamplesIfNeeded() {
        let dir = Self.pluginsDirectory.appendingPathComponent("openai-bridge", isDirectory: true)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard !fm.fileExists(atPath: manifestURL.path) else { return }

        let example: [String: Any] = [
            "id": "openai-bridge",
            "name": "OpenAI Bridge (example)",
            "version": "1.0.0",
            // 默认禁用：这只是一个模板，不是真的插件。
            "enabled": false,
            "capabilities": [
                [
                    "id": "plugin.openai.assist",
                    "display_name": "OpenAI Assist",
                    "kind": "plugin",
                    // 依赖内建 provider 提供的能力：只要 OpenAI 实例可用，
                    // 这条声明在启用后就会显示为可用。
                    "requires": ["openai.chat"],
                    "summary": "Example capability that only works when an OpenAI instance is configured.",
                ]
            ],
        ]
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: example,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 启用/停用一个已安装插件：改写它的 `manifest.json`（`enabled` 字段）
    /// 后重新扫描。只动这一个字段，保留作者写的其它键。
    @discardableResult
    func setEnabled(_ enabled: Bool, pluginID: String) -> Bool {
        let dir = Self.pluginsDirectory.appendingPathComponent(pluginID, isDirectory: true)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            lastError = "No manifest.json for \(pluginID)"
            return false
        }
        object["enabled"] = enabled
        do {
            let out = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: manifestURL, options: .atomic)
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 安装一个本地压缩包（.zip / .tar.gz）为插件：解包到
    /// `plugins/<id>/`，要求解包结果里直接有 `manifest.json`。
    @discardableResult
    func installArchive(_ archive: URL, pluginID: String) -> Bool {
        let dest = Self.pluginsDirectory.appendingPathComponent(pluginID, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            lastError = "Plugin \(pluginID) is already installed"
            return false
        }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if archive.pathExtension.lowercased() == "zip" {
                try BackupZipExtractor.extract(archive, to: dest)
            } else {
                try RuntimeTarGzExtractor.extract(archive, to: dest)
            }
            // Peel a single wrapper directory, same rule as project import.
            let entries = (try? fm.contentsOfDirectory(at: dest,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            if entries.count == 1, let only = entries.first,
               (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               fm.fileExists(atPath: only.appendingPathComponent("manifest.json").path) {
                let tmp = dest.appendingPathComponent(".unwrapped", isDirectory: true)
                try fm.moveItem(at: only, to: tmp)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            }
            guard fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) else {
                lastError = "Archive has no manifest.json at its root"
                try? fm.removeItem(at: dest)
                return false
            }
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            try? fm.removeItem(at: dest)
            return false
        }
    }

    private func apply(manifests: [PluginManifest]) {
        self.manifests = manifests
        guard let bridge else { return }

        let enabled = Set(manifests.filter(\.isEnabled).map(\.id))
        // 1) 下线已消失或已禁用的插件能力。
        for id in bridge.loadedPluginIDs where !enabled.contains(id) {
            bridge.pluginDidUnload(id: id)
        }
        // 2) 注册 / 更新启用插件的声明。
        for manifest in manifests where manifest.isEnabled {
            let declarations = manifest.capabilities ?? []
            guard !declarations.isEmpty else { continue }
            bridge.pluginDidLoad(id: manifest.id, declarations: declarations)
        }
    }
}
