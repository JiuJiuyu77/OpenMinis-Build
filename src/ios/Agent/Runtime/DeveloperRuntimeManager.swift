import CryptoKit
import Foundation

private let logger = AppLogger(category: "Runtime")

/// Layout of the on-disk runtime store.
///
/// Deliberately under Application Support and *not* the App Group container:
/// `MinisFileProvider` exposes the group's user-facing directories to iOS
/// Files, and a 1GB toolchain is neither user content nor something the user
/// should be able to move out from under a running compiler.
enum DeveloperRuntimePaths {
    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeveloperRuntime", isDirectory: true)
    }

    static var installedRoot: URL { root.appendingPathComponent("installed", isDirectory: true) }
    static var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }
    static var downloadRoot: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    static var recordsURL: URL { root.appendingPathComponent("installed.json") }

    static func installDirectory(id: String) -> URL {
        installedRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The archive's root *is* the runtime root (Theos ships `theos/`,
    /// `usr/bin/`, `sdks`… there; portable runtimes ship `bin/`), so the
    /// install directory is the runtime root itself.
    static func runtimeRoot(id: String) -> URL {
        installDirectory(id: id)
    }

    static func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [root, installedRoot, stagingRoot, downloadRoot] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct InstalledRuntimeRecord: Codable, Equatable {
    let id: String
    let version: String
    let revision: String?
    let archiveSHA256: String
    let installedAt: Date
    let sizeBytes: Int64
    let sdk: String?
    let provides: [String]
    /// 装完那一刻按清单 `install` 块做的自检结论。
    /// 旧记录没有这个字段（新增为可选），解码时按 nil 处理。
    var verification: RuntimeVerificationReport?
    /// 装完之后的分发签名结论（ldid → codex-sign）。
    var signing: RuntimeSignReport?
}

enum RuntimeInstallState: Equatable {
    case notInstalled
    case installed(InstalledRuntimeRecord)
    case outdated(InstalledRuntimeRecord)

    var record: InstalledRuntimeRecord? {
        switch self {
        case .notInstalled: return nil
        case .installed(let record), .outdated(let record): return record
        }
    }

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum RuntimeOperation: Equatable {
    case downloading(fraction: Double, bytesWritten: Int64, totalBytes: Int64)
    case verifying
    case extracting(fraction: Double, entries: Int)
    case finalizing
    case cancelling

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .extracting, .finalizing, .cancelling: return true
        }
    }

    var fraction: Double {
        switch self {
        case .downloading(let fraction, _, _), .extracting(let fraction, _): return fraction
        case .verifying: return 0.7
        case .finalizing: return 0.99
        case .cancelling: return 0
        }
    }
}

/// `Equatable` so `catch RuntimeInstallError.cancelled` is a legal expression
/// pattern instead of requiring a `~=` overload.
enum RuntimeInstallError: LocalizedError {
    case badURL(String)
    case httpStatus(Int, String)
    case checksumMismatch(expected: String, actual: String)
    case archiveTooLarge
    case extractionFailed(String)
    case installFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badURL(let url): return "Invalid runtime URL: \(url)"
        case .httpStatus(let code, let host): return "\(host) returned HTTP \(code)"
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
        case .archiveTooLarge: return "Runtime archive exceeds the expected size"
        case .extractionFailed(let reason): return "Extraction failed: \(reason)"
        case .installFailed(let reason): return "Install failed: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Downloads, verifies, extracts and tracks developer runtimes (Theos, OLLVM,
/// ReverseTools, …) described by the published manifest.
///
/// This is a standalone installer: it never touches the chat/AI layer, and a
/// runtime's capabilities become available only through the paths this type
/// reports. Everything heavy runs off the main actor; only `operations` state
/// and the record list are published back to the UI.
@MainActor
final class DeveloperRuntimeManager: ObservableObject {
    static let shared = DeveloperRuntimeManager()

    @Published private(set) var manifest: RuntimeManifest?
    @Published private(set) var manifestError: String?
    @Published private(set) var isLoadingManifest = false
    @Published private(set) var records: [String: InstalledRuntimeRecord] = [:]
    @Published private(set) var operations: [String: RuntimeOperation] = [:]
    @Published private(set) var errors: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static let manifestURL = RuntimeManifestLoader.defaultURL

    init() {
        records = Self.loadRecords()
    }

    // MARK: - Manifest

    /// 故意**不安装**的 handler。
    ///
    /// 清单里的 `codex` 条目是另一套 App 的 AI 执行层（Codex CLI / app-server /
    /// Code Mode Host）。Minis 有自己的 Agent 架构，不接管别人的 agent 运行时：
    /// 这里只消费工具链类运行时（Theos / OLLVM / Node / Python / CoreTools /
    /// ReverseTools），codex 条目在列表里连显示都不该出现，免得用户装一个
    /// 与本 App 无关的 100MB deb。
    static let unsupportedHandlers: Set<String> = ["codex"]

    /// 本 App 会展示与安装的运行时：清单顺序减去不采纳的 handler。
    var runtimes: [RuntimeDescriptor] {
        (manifest?.orderedRuntimes ?? []).filter { descriptor in
            guard let handler = descriptor.handler else { return true }
            return !Self.unsupportedHandlers.contains(handler)
        }
    }

    func loadManifestIfNeeded() async {
        guard manifest == nil, !isLoadingManifest else { return }
        await refreshManifest()
    }

    func refreshManifest() async {
        isLoadingManifest = true
        defer { isLoadingManifest = false }
        do {
            let loaded = try await RuntimeManifestLoader.load()
            manifest = loaded
            manifestError = nil
            pruneRecords()
        } catch {
            manifestError = error.localizedDescription
            logger.warning("Runtime manifest load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - State

    func state(for descriptor: RuntimeDescriptor) -> RuntimeInstallState {
        guard let record = records[descriptor.id],
              FileManager.default.fileExists(
                atPath: DeveloperRuntimePaths.installDirectory(id: descriptor.id).path) else {
            return .notInstalled
        }
        if record.version == descriptor.version, record.revision == descriptor.revision {
            return .installed(record)
        }
        return .outdated(record)
    }

    func operation(for id: String) -> RuntimeOperation? { operations[id] }
    func error(for id: String) -> String? { errors[id] }

    /// Capability identifiers currently backed by an installed runtime.
    var installedCapabilities: Set<String> {
        records.values.reduce(into: Set<String>()) { result, record in
            guard FileManager.default.fileExists(
                atPath: DeveloperRuntimePaths.installDirectory(id: record.id).path) else { return }
            result.formUnion(record.provides)
        }
    }

    /// Runtimes that claim `capability`, installed or not.
    func runtimes(providing capability: String) -> [RuntimeDescriptor] {
        runtimes.filter { ($0.provides ?? []).contains(capability) }
    }

    /// Environment a tool process gets so it can use this runtime in place.
    ///
    /// 清单的 `install.environment` 是运行时自己的契约（Node 的
    /// `CA_TOOL_NODE_RUNTIME_ROOT`、Theos 的 SDK 指向…），`install.path_entries`
    /// 才是真正的 PATH 入口。两代归档布局（Theos 的 `theos/` vs portable 的
    /// `bin/`）由 `RuntimeEnvironmentOverlay` 统一处理，调用方不必知道装的是哪种。
    func environment(for id: String) -> [String: String] {
        guard let descriptor = descriptor(id: id) else { return [:] }
        let root = DeveloperRuntimePaths.runtimeRoot(id: id)
        let overlay = RuntimeEnvironmentOverlay.build(descriptor: descriptor, root: root)
        var env = overlay.exports
        if let prefix = overlay.pathPrefix {
            env["PATH"] = prefix + ":/usr/bin:/bin"
        }
        return env
    }

    /// 安装记录里的自检结论（未装 / 旧记录时为 nil）。
    func verification(for id: String) -> RuntimeVerificationReport? {
        records[id]?.verification
    }

    /// 单项修复用：把重跑自检的结论写回安装记录（不重装、不动文件）。
    func updateVerification(_ report: RuntimeVerificationReport, for id: String) {
        guard var record = records[id] else { return }
        record.verification = report
        records[id] = record
        saveRecords()
    }

    /// 单项修复用：把重新签名的结论写回安装记录。
    func updateSigning(_ report: RuntimeSignReport, for id: String) {
        guard var record = records[id] else { return }
        record.signing = report
        records[id] = record
        saveRecords()
    }

    /// 安装记录里的签名结论。
    func signingReport(for id: String) -> RuntimeSignReport? {
        records[id]?.signing
    }

    /// 按 id 取清单条目（含字典键回填的 id）。
    func descriptor(id: String) -> RuntimeDescriptor? {
        runtimes.first { $0.id == id }
    }

    /// Missing dependencies for `descriptor`, as manifest ids.
    ///
    /// 两类依赖都要算：运行时级 `requires`（裸 id 或对象形式），以及能力级
    /// `capabilities.<id>.requires` —— 后者才是「装的这个东西真能干活」的前提，
    /// 例如 `node.native-addon` 依赖 theos 提供的 `ios.toolchain`。
    func missingRequirements(for descriptor: RuntimeDescriptor) -> [String] {
        let manifest = self.manifest
        var missing: [String] = []
        var seen = Set<String>()

        func require(_ id: String) {
            guard let dependency = manifest?.runtimes[id] else { return }
            let state = self.state(for: dependencyWithID(dependency, id: id))
            if !state.isInstalled, seen.insert(id).inserted {
                missing.append(id)
            }
        }

        for requirement in descriptor.requires ?? [] {
            require(requirement.id)
        }
        for (capability, doc) in descriptor.capabilities ?? [:] {
            guard (descriptor.provides ?? []).contains(capability) else { continue }
            for requirement in doc.requires {
                if manifest?.runtimes[requirement.id] != nil {
                    require(requirement.id)
                } else if let provided = requirement.provides,
                          let provider = runtimes.first(where: {
                              ($0.provides ?? []).contains(provided) && $0.id != descriptor.id
                          }) {
                    require(provider.id)
                }
            }
        }
        return missing
    }

    private func dependencyWithID(_ descriptor: RuntimeDescriptor, id: String) -> RuntimeDescriptor {
        var copy = descriptor
        copy.id = id
        return copy
    }

    // MARK: - Install

    func install(_ descriptor: RuntimeDescriptor) {
        let id = descriptor.id
        guard tasks[id] == nil else { return }
        if let handler = descriptor.handler, Self.unsupportedHandlers.contains(handler) {
            // 防御：清单即使直接塞进来（例如自定义清单地址），也不给装。
            errors[id] = AppLocalized("This runtime belongs to another app's agent stack and is not installed by Minis.")
            return
        }
        guard descriptor.installableArchive else {
            errors[id] = AppLocalized("This runtime uses an archive format the installer cannot unpack (supported: tar.gz and .deb with data.tar.gz / data.tar.zst).")
            return
        }
        errors[id] = nil
        let owner = self
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.performInstall(descriptor, publishingTo: owner)
                self.errors[id] = nil
            } catch is CancellationError {
                logger.notice("Runtime install cancelled: \(id)")
            } catch RuntimeInstallError.cancelled {
                logger.notice("Runtime install cancelled: \(id)")
            } catch {
                logger.error("Runtime install failed (\(id)): \(error.localizedDescription)")
                self.errors[id] = error.localizedDescription
            }
            self.operations[id] = nil
            self.tasks[id] = nil
        }
    }

    /// 安装并等待完成（「一键修复」用）。安装过程仍由 `tasks` 自己管理，
    /// 这里只轮询它的存在，不复制一份安装逻辑。
    func installAndWait(_ descriptor: RuntimeDescriptor, timeout: TimeInterval = 1800) async {
        install(descriptor)
        let deadline = Date().addingTimeInterval(timeout)
        while tasks[descriptor.id] != nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func cancel(_ id: String) {
        guard let task = tasks[id], !task.isCancelled else { return }
        operations[id] = .cancelling
        task.cancel()
    }

    func remove(_ id: String) {
        guard let task = tasks[id] else { return removeFromDisk(id) }
        // Let the installer roll back first: a queued continuation can still
        // move `scratch` into place after this returns, recreating the files.
        operations[id] = .cancelling
        tasks[id] = nil
        task.cancel()
        Task { [weak self] in
            _ = await task.value
            self?.removeFromDisk(id)
        }
    }

    private func removeFromDisk(_ id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: DeveloperRuntimePaths.installDirectory(id: id))
        records[id] = nil
        errors[id] = nil
        operations[id] = nil
        saveRecords()
        logger.notice("Removed runtime \(id)")
    }

    /// `nonisolated static`: the download, hash and unpack all run off the main
    /// actor, and progress is published back through `Task { @MainActor }`.
    private nonisolated static func performInstall(_ descriptor: RuntimeDescriptor,
                                                   publishingTo manager: DeveloperRuntimeManager) async throws {
        try DeveloperRuntimePaths.ensureDirectories()
        guard let archiveURL = URL(string: descriptor.archiveURL) else {
            throw RuntimeInstallError.badURL(descriptor.archiveURL)
        }
        let id = descriptor.id
        let fm = FileManager.default

        let ext = descriptor.archiveFormat == .deb ? "deb" : "tar.gz"
        let archive = DeveloperRuntimePaths.downloadRoot
            .appendingPathComponent("\(id)-\(descriptor.version).\(ext)")
        let scratch = DeveloperRuntimePaths.stagingRoot
            .appendingPathComponent("\(id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: archive) }
        // A failed or cancelled run must not leave a half-extracted tree in
        // staging: it is invisible in the UI but still consumes ~1GB.
        defer { try? fm.removeItem(at: scratch) }

        // 1. Download + hash in one pass, retrying through the published
        // mirrors. Direct GitHub is routinely blocked on some networks, and a
        // runtime that cannot be fetched is the only failure the user sees.
        await manager.publish(id, .downloading(fraction: 0, bytesWritten: 0,
                                               totalBytes: descriptor.downloadBytes))
        var digest = ""
        var lastError: Error?
        for candidate in downloadCandidates(archiveURL) {
            try Task.checkCancellation()
            // A different mirror serves the same bytes, but a partial left by
            // the previous host must not be Range-resumed against it — some
            // proxies answer a Range request with a full body and an etag that
            // does not match the prefix we hashed.
            try? FileManager.default.removeItem(at: archive.appendingPathExtension("part"))
            do {
                digest = try await download(candidate, to: archive,
                                            expectedSize: descriptor.downloadSize) {
                    written, total in
                    Task { @MainActor in
                        manager.operations[id] = .downloading(
                            fraction: total > 0 ? min(1, Double(written) / Double(total)) : 0,
                            bytesWritten: written, totalBytes: total)
                    }
                }
                lastError = nil
                break
            } catch is CancellationError {
                throw RuntimeInstallError.cancelled
            } catch RuntimeInstallError.cancelled {
                throw RuntimeInstallError.cancelled
            } catch {
                lastError = error
                logger.warning("Runtime download failed (\(candidate.absoluteString)): \(error.localizedDescription)")
            }
        }
        if let lastError { throw lastError }
        guard !digest.isEmpty else {
            throw RuntimeInstallError.installFailed("empty archive")
        }

        // 2. Verify before doing any unpacking work.
        await manager.publish(id, .verifying)
        let expected = descriptor.archiveSHA256.lowercased()
        guard digest == expected else {
            throw RuntimeInstallError.checksumMismatch(expected: expected, actual: digest)
        }

        // 3. Extract into staging, then swap in.
        await manager.publish(id, .extracting(fraction: 0, entries: 0))
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let unpacked = descriptor.unpackedBytes
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.unpack(archive: archive,
                                format: descriptor.archiveFormat ?? .tarGz,
                                into: scratch,
                                stagingArea: DeveloperRuntimePaths.stagingRoot,
                                unpackedBytes: unpacked,
                                isCancelled: { Task.isCancelled },
                                progress: { written, entries in
                    let fraction = unpacked > 0
                        ? min(0.99, Double(written) / Double(unpacked))
                        : 0
                    Task { @MainActor in
                        manager.operations[id] = .extracting(
                            fraction: fraction, entries: entries)
                    }
                })
            }.value
        } catch {
            try? fm.removeItem(at: scratch)
            throw RuntimeInstallError.extractionFailed(error.localizedDescription)
        }

        // 3.5 自检：按清单的 required_paths + probe 在 staging 里先验一遍。
        // 坏包（缺 devkit / 缺 framework / probe 起不来）在这里失败，不进 installed/，
        // 也不覆盖上一份可用的安装 —— 换版本失败时用户仍然留着一个能编译的 Theos。
        await manager.publish(id, .verifying)
        // 30 秒缓存的探测结果：沙盒/侧载环境下 probe 记 skipped，而不是判坏包。
        let hostCanRunNative = MinisHostEnvironmentDetector.cached.environment.canRunNativeBinaries
        let verification = await RuntimeInstallVerifier.verify(
            descriptor: descriptor,
            root: scratch,
            canExecuteNative: hostCanRunNative)
        guard verification.isAcceptable else {
            try? fm.removeItem(at: scratch)
            var parts: [String] = []
            if let reason = verification.reason { parts.append(reason) }
            if !verification.missingPaths.isEmpty {
                parts.append(AppLocalized("Missing:") + " " +
                             verification.missingPaths.prefix(6).joined(separator: ", "))
            }
            if let output = verification.probeOutput, !output.isEmpty {
                parts.append(output.split(separator: "\n").prefix(4).joined(separator: " | "))
            }
            throw RuntimeInstallError.installFailed(
                parts.isEmpty ? AppLocalized("Runtime self-check failed.") : parts.joined(separator: " — "))
        }

        // 3.6 签名：ldid 写 entitlements，再让 codex-sign 补 App Store 形态的
        // CodeDirectory。运行时里全是 Mach-O，只做 ldid 会在执行时被杀
        // （Bad executable / Killed: 9）；两者都缺时降级为 adhoc 并在记录里说明。
        let signing = RuntimeSigner.signRuntime(descriptor: descriptor,
                                                root: scratch,
                                                canExecuteNative: hostCanRunNative)
        guard signing.isAcceptable else {
            try? fm.removeItem(at: scratch)
            throw RuntimeInstallError.installFailed(signing.reason ?? AppLocalized("Signing failed."))
        }

        await manager.publish(id, .finalizing)
        let record = InstalledRuntimeRecord(
            id: id,
            version: descriptor.version,
            revision: descriptor.revision,
            archiveSHA256: expected,
            installedAt: Date(),
            sizeBytes: Self.directorySize(scratch),
            sdk: descriptor.sdk,
            provides: descriptor.provides ?? [],
            verification: verification,
            signing: signing)

        if let metadataURL = descriptor.metadataURL.flatMap(URL.init(string:)) {
            await fetchBundleMetadata(metadataURL, into: scratch)
        }
        try Self.writeRecord(record, into: scratch)

        // Swap: move the old install aside, move staging into place, drop the
        // old copy. A failed move leaves the previous install untouched.
        let target = DeveloperRuntimePaths.installDirectory(id: id)
        let retired = DeveloperRuntimePaths.stagingRoot
            .appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fm.fileExists(atPath: target.path)
        if hadPrevious {
            do {
                try fm.moveItem(at: target, to: retired)
            } catch {
                try? fm.removeItem(at: scratch)
                throw RuntimeInstallError.installFailed(error.localizedDescription)
            }
        }
        guard fm.fileExists(atPath: scratch.path) else {
            if hadPrevious { try? fm.moveItem(at: retired, to: target) }
            throw RuntimeInstallError.installFailed("extraction produced no directory")
        }
        do {
            try fm.moveItem(at: scratch, to: target)
        } catch {
            try? fm.removeItem(at: scratch)
            if hadPrevious { try? fm.moveItem(at: retired, to: target) }
            throw RuntimeInstallError.installFailed(error.localizedDescription)
        }
        if hadPrevious { try? fm.removeItem(at: retired) }

        await manager.commit(record)
        // 安装了新运行时（可能就是 OLLVM 前端）后，OLLVM 可用性缓存必须失效，
        // 否则界面会一直显示「缺失」直到杀进程重开。
        await MainActor.run { RuntimeCapabilityNames.refreshOllvmProbe() }
        logger.notice("Installed runtime \(id) \(descriptor.version) (\(record.sizeBytes) bytes, self-check \(verification.status.rawValue), signing \(signing.status.rawValue))")
    }

    // MARK: - Unpacking

    /// Unpack either a `.tar.gz` runtime archive or a `.deb` into `scratch`.
    ///
    /// `.deb` layout: `!<arch>` + `debian-binary` + `control.tar.*` +
    /// `data.tar.*`. Only `data.tar.*` holds the file tree. A `data.tar.zst`
    /// payload is decompressed with libzstd (dlopen) first; if libzstd is
    /// missing on this device the install fails with a message that says so,
    /// rather than a generic "corrupt archive".
    private nonisolated static func unpack(archive: URL,
                                           format: RuntimeDescriptor.ArchiveFormat,
                                           into destination: URL,
                                           stagingArea: URL,
                                           unpackedBytes: Int64,
                                           isCancelled: () -> Bool,
                                           progress: @escaping (Int64, Int) -> Void) throws {
        switch format {
        case .tarGz:
            try RuntimeTarGzExtractor.extract(archive, to: destination,
                                              isCancelled: isCancelled) { p in
                progress(p.bytesWritten, p.entriesWritten)
            }

        case .deb:
            let members = try DebArchive.members(of: archive)
            let data = try DebArchive.dataMember(in: members)
            let memberFile = stagingArea
                .appendingPathComponent("deb-data-\(UUID().uuidString)", isDirectory: false)
            defer { try? FileManager.default.removeItem(at: memberFile) }
            try DebArchive.extract(data, from: archive, to: memberFile)

            if DebArchive.isGzipPayload(data.name) {
                try RuntimeTarGzExtractor.extract(memberFile, to: destination,
                                                  isCancelled: isCancelled) { p in
                    progress(p.bytesWritten, p.entriesWritten)
                }
            } else if DebArchive.isExternalPayload(data.name) {
                guard data.name.hasSuffix(".tar.zst") else {
                    // .tar.xz / .tar.bz2: no in-process decoder available.
                    throw RuntimeInstallError.extractionFailed(
                        "This package ships \(data.name); only .tar.gz and .tar.zst payloads can be unpacked here.")
                }
                let tarFile = stagingArea
                    .appendingPathComponent("deb-tar-\(UUID().uuidString)", isDirectory: false)
                defer { try? FileManager.default.removeItem(at: tarFile) }
                try ZstdDecompressor.decompress(memberFile, to: tarFile)
                try RuntimeTarGzExtractor.extractPlainTar(tarFile, to: destination,
                                                          isCancelled: isCancelled) { p in
                    progress(p.bytesWritten, p.entriesWritten)
                }
            } else {
                // Uncompressed data.tar
                try RuntimeTarGzExtractor.extractPlainTar(memberFile, to: destination,
                                                          isCancelled: isCancelled) { p in
                    progress(p.bytesWritten, p.entriesWritten)
                }
            }
        }
    }

    // MARK: - Networking

    private nonisolated static func downloadCandidates(_ url: URL) -> [URL] {
        var candidates = [url]
        for prefix in RuntimeManifestLoader.mirrorPrefixes where !prefix.isEmpty {
            if let mirrored = URL(string: prefix + url.absoluteString) {
                candidates.append(mirrored)
            }
        }
        return candidates
    }

    /// Session used for runtime downloads.
    ///
    /// [T-runtime-download-timeout] `URLSession.shared` carries
    /// `timeoutIntervalForRequest = 60`, which is a *gap* between chunks but is
    /// also applied to the initial TLS+redirect leg. Codex's 100 MB `.deb`
    /// comes from a redirected CDN that regularly takes longer than that to
    /// start, so every attempt died with "The request timed out" and the
    /// runtime looked un-installable. Give downloads their own session with a
    /// generous idle timeout and a long overall ceiling.
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120      // per-chunk gap
        config.timeoutIntervalForResource = 60 * 60 * 2  // whole transfer
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    /// Attempts per candidate URL, resuming from the bytes already on disk.
    private static let downloadRetries = 3

    /// Streams `url` to disk and returns the lowercase hex SHA-256 of the bytes
    /// received, so verification never re-reads a 200MB file.
    ///
    /// A dropped connection resumes with `Range: bytes=<n>-` and the hash is
    /// primed from the prefix already written, so a 100 MB package on a flaky
    /// link does not restart from zero three times in a row.
    private nonisolated static func download(_ url: URL,
                                             to destination: URL,
                                             expectedSize: Int64?,
                                             progress: @escaping (Int64, Int64) -> Void) async throws -> String {
        // Write to `.part` and move on success: a killed download must never
        // leave a truncated file that looks like a verified archive.
        let partial = destination.appendingPathExtension("part")

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await downloadOnce(url, partial: partial,
                                              expectedSize: expectedSize,
                                              progress: progress)
            } catch is CancellationError {
                throw RuntimeInstallError.cancelled
            } catch RuntimeInstallError.cancelled {
                throw RuntimeInstallError.cancelled
            } catch let error as RuntimeInstallError {
                // HTTP 4xx (other than 408/429) will not improve by retrying.
                if case .httpStatus(let code, _) = error, (400..<500).contains(code),
                   code != 408, code != 429 {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
                if attempt >= downloadRetries {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
                logger.warning("Runtime download attempt \(attempt) failed (\(error.localizedDescription)); resuming")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
            } catch {
                if attempt >= downloadRetries {
                    try? FileManager.default.removeItem(at: partial)
                    throw RuntimeInstallError.installFailed(error.localizedDescription)
                }
                logger.warning("Runtime download attempt \(attempt) failed (\(error.localizedDescription)); resuming")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
            }
        }
    }

    /// One request, appending to whatever `partial` already holds.
    private nonisolated static func downloadOnce(_ url: URL,
                                                 partial: URL,
                                                 expectedSize: Int64?,
                                                 progress: @escaping (Int64, Int64) -> Void) async throws -> String {
        let fm = FileManager.default
        var hasher = SHA256()
        var already: Int64 = 0

        // Prime the hash from the bytes we already have, then ask for the rest.
        if let attrs = try? fm.attributesOfItem(atPath: partial.path),
           let size = attrs[.size] as? Int64, size > 0 {
            if let handle = try? FileHandle(forReadingFrom: partial) {
                defer { try? handle.close() }
                while true {
                    let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
                    guard let chunk, !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                    already += Int64(chunk.count)
                }
            }
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        if already > 0 {
            // A server that ignores Range replies 200 with the whole body; we
            // detect that below by truncating `partial` first.
            request.setValue("bytes=\(already)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await downloadSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RuntimeInstallError.badURL(url.absoluteString)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RuntimeInstallError.httpStatus(http.statusCode, url.host ?? "server")
        }

        let resumed = (http.statusCode == 206)
        if already > 0 && !resumed {
            // Range ignored: start over rather than appending a whole body to
            // a prefix (that would corrupt both the file and the hash).
            try? fm.removeItem(at: partial)
            hasher = SHA256()
            already = 0
        }

        let total = http.expectedContentLength > 0
            ? http.expectedContentLength + already
            : (expectedSize ?? 0)
        if let expectedSize, total > expectedSize + 1024 * 1024 {
            throw RuntimeInstallError.archiveTooLarge
        }

        fm.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw RuntimeInstallError.installFailed(error.localizedDescription)
        }

        var written = already
        var buffer = Data()
        buffer.reserveCapacity(1024 * 1024)
        var lastReport = Date.distantPast

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1024 * 1024 {
                    try handle.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        progress(written, total)
                    }
                    if Task.isCancelled { throw RuntimeInstallError.cancelled }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                written += Int64(buffer.count)
            }
        } catch let error as RuntimeInstallError {
            try? handle.close()
            throw error
        } catch is CancellationError {
            try? handle.close()
            throw RuntimeInstallError.cancelled
        } catch {
            // Keep the partial: the retry resumes from here.
            try? handle.close()
            throw RuntimeInstallError.installFailed(error.localizedDescription)
        }
        try handle.close()

        // A truncated transfer (connection closed early) must not be mistaken
        // for a complete file: it would fail the SHA check anyway, but retrying
        // is far better than surfacing a checksum mismatch to the user.
        if let expectedSize, expectedSize > 0, written < expectedSize {
            throw RuntimeInstallError.installFailed(
                "Transfer ended early (\(written) of \(expectedSize) bytes)")
        }

        try? fm.removeItem(at: destination_(for: partial))
        do {
            try fm.moveItem(at: partial, to: destination_(for: partial))
        } catch {
            throw RuntimeInstallError.installFailed(error.localizedDescription)
        }
        progress(written, total)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `foo.deb.part` → `foo.deb`
    private nonisolated static func destination_(for partial: URL) -> URL {
        partial.deletingPathExtension()
    }

    private nonisolated static func fetchBundleMetadata(_ url: URL, into directory: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            try data.write(to: directory.appendingPathComponent("runtime-bundle.json"),
                           options: .atomic)
        } catch {
            // Metadata is advisory (post-install layout hints). The tarball
            // itself is already checksum-verified, so this must not fail the
            // install.
            logger.warning("Runtime bundle metadata fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Records

    private nonisolated static func writeRecord(_ record: InstalledRuntimeRecord, into directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(record)
            try data.write(to: directory.appendingPathComponent(".runtime-record.json"),
                           options: .atomic)
        } catch {
            throw RuntimeInstallError.installFailed(error.localizedDescription)
        }
    }

    private static func loadRecords() -> [String: InstalledRuntimeRecord] {
        guard let data = try? Data(contentsOf: DeveloperRuntimePaths.recordsURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([String: InstalledRuntimeRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func saveRecords() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? DeveloperRuntimePaths.ensureDirectories()
        try? data.write(to: DeveloperRuntimePaths.recordsURL, options: .atomic)
    }

    /// Called once the new install is swapped into place.
    fileprivate func commit(_ record: InstalledRuntimeRecord) {
        records[record.id] = record
        saveRecords()
    }

    /// Publishes progress from the nonisolated install pipeline.
    nonisolated func publish(_ id: String, _ operation: RuntimeOperation?) async {
        await Task { @MainActor in
            self.operations[id] = operation
        }.value
    }

    /// Drop records whose directory disappeared (deleted by iOS, restored
    /// backup, user cleanup) so the UI never reports a phantom install.
    private func pruneRecords() {
        let fm = FileManager.default
        let missing = records.keys.filter {
            !fm.fileExists(atPath: DeveloperRuntimePaths.installDirectory(id: $0).path)
        }
        guard !missing.isEmpty else { return }
        for id in missing { records[id] = nil }
        saveRecords()
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
