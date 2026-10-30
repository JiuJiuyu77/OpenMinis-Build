import Foundation

/// Manages optional SDKs on the device. The large SDK payload is intentionally
/// not copied into the app source tree; users import it once from Files into
/// the installed Theos runtime, then builds select it by SDKVERSION.
enum BuildSDKManager {
    static func sdkURL(_ version: BuildSDKVersion) -> URL? {
        guard let root = NativeToolchain.shared.theosRoot else { return nil }
        let candidates = [
            root.appendingPathComponent("sdks/iPhoneOS\(version.rawValue).sdk", isDirectory: true),
            root.appendingPathComponent("theos/sdks/iPhoneOS\(version.rawValue).sdk", isDirectory: true)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first
    }

    static func isInstalled(_ version: BuildSDKVersion) -> Bool {
        guard let url = sdkURL(version) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("SDKSettings.plist").path)
    }

    /// Copies an imported iPhoneOS26.0.sdk into the native Theos root.
    /// The source is security-scoped and is never executed.
    static func installImportedSDK(from source: URL, version: BuildSDKVersion = .sdk260) throws -> URL {
        guard let destination = sdkURL(version) else {
            throw NSError(domain: "MinisBuildSDK", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未找到可写的 Theos 根目录，请先安装原生运行时。"])
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "MinisBuildSDK", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "请选择解压后的 iPhoneOS26.0.sdk 文件夹。"])
        }
        let settings = source.appendingPathComponent("SDKSettings.plist")
        guard FileManager.default.fileExists(atPath: settings.path) else {
            throw NSError(domain: "MinisBuildSDK", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "SDK 缺少 SDKSettings.plist，未执行导入。"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".iPhoneOS\(version.rawValue).sdk.import-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: staging)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        return destination
    }
}
