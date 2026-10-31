import Foundation
import Security
import WebKit

/// Removes Minis-owned state so the next launch follows the first-install path.
/// This is local-only: it does not delete the user's iCloud records.
enum FreshInstallReset {
    struct Result: Sendable {
        let removedPaths: Int
        let keychainItems: Int
        let failedPaths: [String]
    }

    private struct DeletionResult: Sendable {
        let removedPaths: Int
        let keychainItems: Int
        let failedPaths: [String]
    }

    private static let logger = AppLogger(category: "FreshInstallReset")
    private static let appGroupID = SharedContainerStore.appGroupID
    // All app-owned generic-password services use this bundle prefix. Keeping
    // the filter bundle-scoped avoids deleting credentials belonging to other
    // apps while still covering newly added providers/services.
    private static let keychainServicePrefixes = ["com.openminis.app."]

    @MainActor
    static func perform() async throws -> Result {
        logger.warning("reset requested")

        // Stop producers before deleting their backing files. This is the same
        // cascade used by the normal session-delete funnel, but global.
        for job in AgentJobRegistry.shared.list() {
            AgentJobRegistry.shared.cancel(jobId: job.id, reason: "freshInstallReset", silent: true)
        }
        _ = ISHExecutionCoordinator.stopAllNonisolated()
        VoiceOutputPlayer.shared.stopAll()
        if #available(iOS 17.0, *) {
            CloudSyncEngine.shared.isEnabled = false
            SyncV2Bootstrap.setEnabled(false)
        }
        await ChatStore.shared.closeDatabase()

        // Only rename the live rootfs on the main actor. Recursive deletion is
        // moved to a utility task below, avoiding a watchdog during large reset.
        var preparationFailures: [String] = []
        do {
            _ = try RootfsManager.shared.prepareForFreshInstallReset()
        } catch {
            preparationFailures.append("alpine-rootfs: \(error.localizedDescription)")
        }

        URLCache.shared.removeAllCachedResponses()
        await clearWebData()
        let paths = uniqueSafeURLs(resetRoots() + staleRootfsPaths())
        let deletion = await Task.detached(priority: .utility) {
            deletePathsAndKeychain(paths)
        }.value

        resetUserDefaults()
        SharedContainerStore.sharedDefaults?.removePersistentDomain(forName: appGroupID)
        SharedContainerStore.clearPendingShare()
        SharedContainerStore.cleanSharedFiles()
        ThumbnailCache.shared.removeAll()

        let failures = preparationFailures + deletion.failedPaths
        logger.warning("reset complete paths=\(deletion.removedPaths) keychain=\(deletion.keychainItems) failures=\(failures.count)")
        return Result(removedPaths: deletion.removedPaths,
                      keychainItems: deletion.keychainItems,
                      failedPaths: failures)
    }

    private static func deletePathsAndKeychain(_ paths: [URL]) -> DeletionResult {
        let fm = FileManager.default
        var removed = 0
        var failures: [String] = []
        for url in paths where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                failures.append("\(url.path): \(error.localizedDescription)")
            }
        }
        return DeletionResult(removedPaths: removed,
                              keychainItems: deleteMinisKeychainItems(),
                              failedPaths: failures)
    }

    private static func clearWebData() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private static func staleRootfsPaths() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil, options: []
        )) ?? []
        return names.filter {
            $0.hasDirectoryPath
                && $0.lastPathComponent.range(
                    of: #"^\.alpine-rootfs-(broken|reset)-[A-F0-9-]+$"#,
                    options: .regularExpression
                ) != nil
        }
    }

    private static func resetRoots() -> [URL] {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var roots: [URL] = [
            library.appendingPathComponent("MinisChat", isDirectory: true),
            library.appendingPathComponent("Logs", isDirectory: true),
            caches.appendingPathComponent("com.openminis.app", isDirectory: true),
            appSupport.appendingPathComponent("DeveloperRuntime", isDirectory: true),
            appSupport.appendingPathComponent("NativeToolchain", isDirectory: true),
            appSupport.appendingPathComponent("MinisProjects", isDirectory: true),
            appSupport.appendingPathComponent("BrowserCookieBackup", isDirectory: true),
            appSupport.appendingPathComponent("DebugAuth", isDirectory: true),
            appSupport.appendingPathComponent("Quota", isDirectory: true),
            appSupport.appendingPathComponent("BackupHistory", isDirectory: true),
            appSupport.appendingPathComponent("BackupRestore", isDirectory: true),
            appSupport.appendingPathComponent("BackupExport", isDirectory: true),
            appSupport.appendingPathComponent("launch_marker"),
            appSupport.appendingPathComponent("last_hang_snapshot.txt"),
            appSupport.appendingPathComponent("last_crash_stack.txt"),
            appSupport.appendingPathComponent("last_tool_exec.txt"),
            appSupport.appendingPathComponent("last_heartbeat.json"),
            documents.appendingPathComponent("alpine-rootfs", isDirectory: true),
            documents.appendingPathComponent("CodexAttachments", isDirectory: true),
            documents.appendingPathComponent("CodexPastes", isDirectory: true),
            documents.appendingPathComponent(".codex", isDirectory: true),
            DeveloperRuntimePaths.root,
            AIChatViewModel.minisAppGroupRoot,
            AIChatViewModel.minisConfigRoot
        ]
        roots += (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil, options: []))?.filter {
            $0.lastPathComponent.hasPrefix("com.openminis.app")
                || $0.lastPathComponent.hasPrefix("Minis")
        } ?? []
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            roots += [
                group.appendingPathComponent("ShareExtension", isDirectory: true),
                group.appendingPathComponent("MinisFileProvider", isDirectory: true),
                group.appendingPathComponent("MinisConfig", isDirectory: true)
            ]
        }
        return uniqueSafeURLs(roots)
    }

    private static func uniqueSafeURLs(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let forbidden = Set([home, library, documents])
        var result: [URL] = []
        for url in urls.map({ $0.standardizedFileURL }) {
            let path = url.path
            // Every candidate is constructed from one of the app's own
            // container roots above. Reject the roots themselves and never use
            // substring matching as an ownership check.
            guard path.count > 12, !forbidden.contains(path) else { continue }
            if !result.contains(where: { $0.path == path }) { result.append(url) }
        }
        return result
    }

    private static func deleteMinisKeychainItems() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return 0 }
        var removed = 0
        for item in items {
            guard let service = item[kSecAttrService as String] as? String,
                  keychainServicePrefixes.contains(where: service.hasPrefix) else { continue }
            let account = item[kSecAttrAccount as String] ?? ""
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let legacyStatus = SecItemDelete(base as CFDictionary)
            var sync = base
            sync[kSecAttrSynchronizable as String] = true
            let syncStatus = SecItemDelete(sync as CFDictionary)
            if legacyStatus == errSecSuccess || syncStatus == errSecSuccess { removed += 1 }
        }
        return removed
    }

    private static func resetUserDefaults() {
        // The app's persistent domain contains all @AppStorage/config flags.
        // Removing only a hand-maintained key list is how stale settings survive
        // a reset, so clear the bundle domain as one atomic policy decision.
        let ud = UserDefaults.standard
        if let bundleID = Bundle.main.bundleIdentifier {
            ud.removePersistentDomain(forName: bundleID)
        }
        ud.synchronize()
    }
}
