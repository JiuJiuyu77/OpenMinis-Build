import Foundation

private let logger = AppLogger(category: "Runtime")

/// A suggested companion runtime (`recommends` in the manifest). Unlike
/// `requires`, these are objects with a human-readable reason, not bare ids.
struct RuntimeRecommendation: Codable, Hashable {
    let id: String
    let provides: String?
    let reason: String?
}

/// One entry of `requires`. The manifest publishes both shapes — bare ids in
/// older entries and `{id, provides, reason}` objects in newer ones — so decoding
/// accepts either instead of silently dropping the dependency.
struct RuntimeRequirement: Codable, Hashable {
    let id: String
    let provides: String?
    let reason: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let bare = try? single.decode(String.self) {
            id = bare
            provides = nil
            reason = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provides = try? container.decodeIfPresent(String.self, forKey: .provides)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
    }

    enum CodingKeys: String, CodingKey { case id, provides, reason }
}

/// One entry of the developer runtime manifest (`runtime-manifest.json`,
/// schema 4). The manifest is published alongside the runtime tarballs; it is
/// data only, so adding a runtime never requires a new app build.
struct RuntimeDescriptor: Codable, Identifiable, Hashable {
    /// Dictionary key of the manifest, filled in by `RuntimeManifest` after
    /// decoding. Deliberately absent from `CodingKeys`: the published manifest
    /// keys each runtime by this id instead of repeating it in the object.
    var id: String = ""
    let displayName: String
    let version: String
    let revision: String?
    let summary: String?
    let handler: String?
    let group: String?
    let order: Int?
    let optional: Bool?
    let minimumIOS: String?
    let archiveURL: String
    let archiveSHA256: String
    let metadataURL: String?
    let downloadSize: Int64?
    let unpackedSize: Int64?
    let provides: [String]?
    let requires: [RuntimeRequirement]?
    let recommends: [RuntimeRecommendation]?
    let conflicts: [String]?
    let packageSchemes: [String]?
    let sdk: String?
    let capabilities: [String: RuntimeCapability]?
    let ui: RuntimeUI?
    let assetName: String?
    let runtimeFormat: Int?
    /// 清单里的 `install` 块：自检三元组、PATH 入口与运行时环境。
    /// App 自管 handler（codex / theos / python / reverse_tools）不发布这个字段。
    var install: RuntimeInstallSpec? = nil

    struct RuntimeCapability: Codable, Hashable {
        let title: String?
        let summary: String?
        let minVersion: String?
        /// 跨运行时依赖：`node.native-addon` 需要 theos 的 ios.toolchain 之类。
        let requires: [RuntimeRequirement]

        enum CodingKeys: String, CodingKey {
            case title, summary, requires
            case minVersion = "min_version"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            summary = try? container.decodeIfPresent(String.self, forKey: .summary)
            minVersion = try? container.decodeIfPresent(String.self, forKey: .minVersion)
            requires = (try? container.decodeIfPresent([RuntimeRequirement].self,
                                                       forKey: .requires)) ?? []
        }
    }

    struct RuntimeUI: Codable, Hashable {
        let symbol: String?
        let tint: String?
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case version
        case revision
        case summary
        case handler
        case group
        case order
        case optional
        case minimumIOS = "minimum_ios"
        case archiveURL = "archive_url"
        case archiveSHA256 = "archive_sha256"
        case metadataURL = "metadata_url"
        case downloadSize = "download_size"
        case unpackedSize = "unpacked_size"
        case provides
        case requires
        case recommends
        case conflicts
        case packageSchemes = "package_schemes"
        case sdk
        case capabilities
        case ui
        case assetName = "asset_name"
        case runtimeFormat = "runtime_format"
        case install
    }

    /// 没有 `install` 块时返回空规格，调用方不必到处判断可选值。
    var installSpecOrNone: RuntimeInstallSpec { install ?? .none }

    var downloadBytes: Int64 { downloadSize ?? 0 }
    var unpackedBytes: Int64 { unpackedSize ?? 0 }
    /// Sequential order inside a group; the manifest uses 5/10/15/20/30.
    var sortOrder: Int { order ?? 100 }

    /// Archive formats this installer understands.
    enum ArchiveFormat: String {
        case tarGz
        /// Debian package. Unpacked by reading the `ar` members and extracting
        /// `data.tar.*`; `.tar.zst` additionally needs libzstd (dlopen).
        case deb
    }

    var archiveFormat: ArchiveFormat? {
        let path = (assetName ?? archiveURL).lowercased()
        if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") { return .tarGz }
        if path.hasSuffix(".deb") { return .deb }
        return nil
    }

    /// The installer unpacks gzip tarballs directly and Debian packages by
    /// reading their data member, so nothing in the current manifest is
    /// un-installable on format grounds alone.
    var installableArchive: Bool { archiveFormat != nil }
}

struct RuntimeManifest: Codable {
    let schema: Int?
    let sourceName: String?
    let sourceFormat: Int?
    let downloadProxyPrefixes: [String]?
    let runtimes: [String: RuntimeDescriptor]

    enum CodingKeys: String, CodingKey {
        case schema
        case sourceName = "source_name"
        case sourceFormat = "source_format"
        case downloadProxyPrefixes = "download_proxy_prefixes"
        case runtimes
    }

    /// Stable display order: `compiler` first (Theos is what makes the rest
    /// usable), then `tools`, then anything unknown, each by `order` then name.
    var orderedRuntimes: [RuntimeDescriptor] {
        runtimes.map { key, value in
            descriptorWithID(key, value)
        }
        .sorted { lhs, rhs in
            let lg = groupRank(lhs.group), rg = groupRank(rhs.group)
            if lg != rg { return lg < rg }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func groupRank(_ group: String?) -> Int {
        switch group {
        case "compiler": return 0
        case "core": return 1
        case "tools": return 2
        default: return 3
        }
    }

    private func descriptorWithID(_ id: String, _ descriptor: RuntimeDescriptor) -> RuntimeDescriptor {
        var copy = descriptor
        copy.id = id
        return copy
    }
}

enum RuntimeManifestLoader {

    /// 运行时清单地址：默认指向本项目的运行时仓库（JiuJiuyu77/MinisApp-Runtime）。
    /// 设置 → 运行时诊断 里可以覆盖成任意镜像/自建仓库，不必重新编译。
    static let defaultURL = URL(string:
        "https://raw.githubusercontent.com/JiuJiuyu77/MinisApp-Runtime/main/Runtime/runtime-manifest.json")!

    /// 用户自定义清单地址（设置 → 运行时诊断 → 运行时清单地址）。
    static let overrideURLKey = "developerRuntime.manifestURLOverride"

    /// 实际使用的清单地址：用户覆盖优先，否则用默认仓库。
    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: overrideURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let url = URL(string: raw), url.scheme != nil { return url }
        return defaultURL
    }

    static var overrideURLString: String {
        (UserDefaults.standard.string(forKey: overrideURLKey) ?? "")
    }

    static func setOverrideURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: overrideURLKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: overrideURLKey)
        }
    }

    enum LoadError: LocalizedError {
        case badStatus(Int)
        case invalidManifest(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "Runtime manifest request failed (HTTP \(code))"
            case .invalidManifest(let reason): return "Runtime manifest is invalid: \(reason)"
            }
        }
    }

    private static var cacheURL: URL {
        DeveloperRuntimePaths.root.appendingPathComponent("manifest.json")
    }

    /// Fetch the manifest, falling back to the mirror prefixes in the previous
    /// copy and finally to the on-disk cache. GitHub is not reliably reachable
    /// from every network, and a cached manifest still lets an already
    /// installed runtime be updated from its pinned URL.
    static func load() async throws -> RuntimeManifest {
        var lastError: Error?

        for attempt in attempts(source: manifestURL, prefixes: mirrorPrefixes) {
            do {
                let (payload, response) = try await URLSession.shared.data(from: attempt)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw LoadError.badStatus(http.statusCode)
                }
                let data = try unwrapProxyEnvelope(payload)
                let manifest = try decode(data)
                try? FileManager.default.createDirectory(
                    at: DeveloperRuntimePaths.root, withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
                if let published = manifest.downloadProxyPrefixes, !published.isEmpty {
                    publishMirrors(published)
                }
                return manifest
            } catch {
                lastError = error
                logger.warning("Manifest attempt failed (\(attempt.absoluteString)): \(error.localizedDescription)")
            }
        }

        if let cached = try? Data(contentsOf: cacheURL), let manifest = try? decode(cached) {
            logger.notice("Using cached runtime manifest after network failure")
            return manifest
        }
        throw lastError ?? LoadError.invalidManifest("empty manifest")
    }

    /// Mirror prefixes used when the primary host is unreachable.
    ///
    /// Seeded from `download_proxy_prefixes` in schema 4 and extended by any
    /// manifest fetched in this process. Deliberately a fixed list rather than
    /// "whatever a previous cache said": prefixing a URL that is already
    /// prefixed produces an invalid nested URL, so the source of truth must not
    /// be a value that may itself have come from a mirrored response.
    static var mirrorPrefixes: [String] {
        mirrorQueue.sync { manifestMirrors.isEmpty ? defaultMirrorPrefixes : manifestMirrors }
    }

    private static let mirrorQueue = DispatchQueue(label: "com.openminis.runtime.mirrors")
    private static let defaultMirrorPrefixes = [
        "https://gh-proxy.org/",
        "https://ghproxy.net/"
    ]

    private static var manifestMirrors: [String] = []

    private static func publishMirrors(_ prefixes: [String]) {
        mirrorQueue.sync { manifestMirrors = prefixes }
    }

    private static func attempts(source: URL, prefixes: [String]) -> [URL] {
        var urls = [source]
        for prefix in prefixes where !prefix.isEmpty {
            if let candidate = URL(string: prefix + source.absoluteString) {
                urls.append(candidate)
            }
        }
        return urls
    }

    /// Public mirror proxies wrap raw files in a small JSON envelope. Detect and
    /// unwrap it so a mirror response is never mistaken for a bad manifest.
    private static func unwrapProxyEnvelope(_ data: Data) throws -> Data {
        guard data.first == UInt8(ascii: "{") else { return data }
        if (try? JSONDecoder().decode(RuntimeManifest.self, from: data)) != nil {
            return data
        }
        struct Envelope: Decodable { let content: String? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let content = envelope.content,
              let unwrapped = content.data(using: .utf8) else {
            return data
        }
        return unwrapped
    }

    private static func decode(_ data: Data) throws -> RuntimeManifest {
        do {
            let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
            guard !manifest.runtimes.isEmpty else {
                throw LoadError.invalidManifest("no runtimes")
            }
            return manifest
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.invalidManifest(error.localizedDescription)
        }
    }
}

// MARK: - 可选版本（Codex）

/// 从运行时仓库的 GitHub Releases 里列出可安装的版本。
///
/// 运行时清单只带「最新版」一条，但 Codex 的每个版本都是同一套 deb 布局，
/// 换 `archive_url` / `archive_sha256` / `version` 就能装旧版。这里把 release
/// 列表拉出来，让设置页可以选版本，而不是只能装清单里的那一版。
enum RuntimeVersionCatalog {

    struct Option: Identifiable, Sendable, Hashable {
        let id: String          // tag
        let version: String     // 展示用版本号
        let assetName: String
        let archiveURL: String
        let sha256: String
        let size: Int64
        let publishedAt: Date?
    }

    /// 运行时仓库的 `owner/repo`，从清单地址推出来；默认仓库也能解析。
    static var repositorySlug: String? {
        let url = RuntimeManifestLoader.manifestURL
        guard url.host?.contains("githubusercontent") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[0] + "/" + parts[1]
    }

    /// 列出某个 handler 的可选版本，按发布时间倒序。
    static func versions(handler: String, limit: Int = 12) async -> [Option] {
        guard let slug = repositorySlug,
              let url = URL(string: "https://api.github.com/repos/\(slug)/releases?per_page=100") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let prefix = "runtime-\(handler)-"
        var options: [Option] = []
        for release in releases {
            guard let tag = release["tag_name"] as? String, tag.hasPrefix(prefix),
                  let assets = release["assets"] as? [[String: Any]] else { continue }
            guard let deb = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".deb") == true }),
                  let debName = deb["name"] as? String,
                  let debURL = deb["browser_download_url"] as? String,
                  let sums = assets.first(where: { ($0["name"] as? String) == "SHA256SUMS" }),
                  let sumsURL = sums["browser_download_url"] as? String else { continue }
            guard let sha = await sha256(for: debName, sumsURL: sumsURL) else { continue }
            let published = (release["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let version = tag.replacingOccurrences(of: prefix, with: "")
            options.append(Option(id: tag,
                                  version: version,
                                  assetName: debName,
                                  archiveURL: debURL,
                                  sha256: sha,
                                  size: (deb["size"] as? Int64) ?? Int64((deb["size"] as? Int) ?? 0),
                                  publishedAt: published))
            if options.count >= limit { break }
        }
        return options
    }

    private static func sha256(for name: String, sumsURL: String) async -> String? {
        guard let url = URL(string: sumsURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let file = parts.last!.hasPrefix("*") ? String(parts.last!.dropFirst()) : parts.last!
            if file == name { return parts[0].lowercased() }
        }
        return nil
    }
}

extension RuntimeDescriptor {
    /// 用另一个 release 的版本信息替换这个 descriptor，其余字段保持不变。
    func replacingRelease(version: String, assetName: String, archiveURL: String, sha256: String, size: Int64) -> RuntimeDescriptor {
        RuntimeDescriptor(id: id,
                          displayName: displayName,
                          version: version,
                          revision: revision,
                          summary: summary,
                          handler: handler,
                          group: group,
                          order: order,
                          optional: optional,
                          minimumIOS: minimumIOS,
                          archiveURL: archiveURL,
                          archiveSHA256: sha256,
                          metadataURL: metadataURL,
                          downloadSize: size,
                          unpackedSize: unpackedSize,
                          provides: provides,
                          requires: requires,
                          recommends: recommends,
                          conflicts: conflicts,
                          packageSchemes: packageSchemes,
                          sdk: sdk,
                          capabilities: capabilities,
                          ui: ui,
                          assetName: assetName,
                          runtimeFormat: runtimeFormat)
    }
}
