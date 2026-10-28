//
//  IPAShellPacker.swift
//  Minis — 打壳：给已有 .ipa 注入构建出的 dylib，重打包成新 .ipa
//
//  「打壳」在越狱圈里指：拿一个已签名的 App 包，把 dylib 塞进
//  `Payload/X.app/Frameworks/`，再在主二进制的 Load Command 里加一条
//  `LC_LOAD_DYLIB`，最后重新压成 ipa。dylib 由 Theos 工程编出来
//  （`product == .dylib`），所以这一步天然接在编译之后。
//
//  两件事必须说清楚，不能假装成功：
//    1. 注入会让原签名失效 → 打壳收尾就地用 ldid + codex-sign 重签；
//       工具不可用时明确标成 needsResign，交给用户/CI；
//    2. 注入需要 Load Command 区有空隙 → 没有空隙时明确报错，而不是产出
//       一个装上去就闪退的包。
//

import Foundation

private let logger = AppLogger(category: "Build")

enum IPAShellPacker {

    enum ShellError: LocalizedError {
        case sourceMissing(String)
        case dylibMissing(String)
        case notAnIPA
        case noPayloadApp
        case noExecutable(String)
        case injectFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let p): return "Source .ipa not found: \(p)"
            case .dylibMissing(let p): return "Built dylib not found: \(p)"
            case .notAnIPA: return "The source file is not a .ipa (needs Payload/<App>.app/main)"
            case .noPayloadApp: return "The .ipa has no Payload/*.app directory"
            case .noExecutable(let app): return "Could not find the main executable inside \(app)"
            case .injectFailed(let r): return "Mach-O injection failed: \(r)"
            case .writeFailed(let r): return "Could not write the repackaged .ipa: \(r)"
            }
        }
    }

    struct Outcome {
        let ipa: URL
        let appPath: String
        let executable: String
        let injectedDylib: String
        let needsResign: Bool
        /// 注入后的签名结论：ldid + codex-sign 成功时 needsResign 为 false。
        let signing: RuntimeSignReport?
    }

    /// Inject `dylib` into `sourceIPA` and write a new ipa to `output`.
    ///
    /// - Parameters:
    ///   - dylib: the `.dylib` produced by the build.
    ///   - workDirectory: scratch directory; cleared on entry.
    ///   - onLog: progress lines for the build log.
    static func pack(sourceIPA: URL,
                     dylib: URL,
                     output: URL,
                     workDirectory: URL,
                     onLog: @escaping (String) -> Void) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceIPA.path) else {
            throw ShellError.sourceMissing(sourceIPA.path)
        }
        guard fm.fileExists(atPath: dylib.path) else {
            throw ShellError.dylibMissing(dylib.path)
        }

        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        onLog("▸ 解包 \(sourceIPA.lastPathComponent)…")
        try BackupZipExtractor.extract(sourceIPA, to: workDirectory)

        let payload = workDirectory.appendingPathComponent("Payload", isDirectory: true)
        let apps = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw ShellError.noPayloadApp }

        // Main executable: CFBundleExecutable, falling back to the bundle name.
        let plistURL = app.appendingPathComponent("Info.plist")
        var execName = app.deletingPathExtension().lastPathComponent
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let declared = plist["CFBundleExecutable"] as? String, !declared.isEmpty {
            execName = declared
        }
        let executable = app.appendingPathComponent(execName)
        guard fm.fileExists(atPath: executable.path) else {
            throw ShellError.noExecutable(app.lastPathComponent)
        }

        // Copy the dylib in, creating Frameworks/ when absent.
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let dylibTarget = frameworks.appendingPathComponent(dylib.lastPathComponent)
        try? fm.removeItem(at: dylibTarget)
        try fm.copyItem(at: dylib, to: dylibTarget)
        onLog("▸ 已复制 dylib → Frameworks/\(dylib.lastPathComponent)")

        // Patch the main executable.
        do {
            let outcome = try MachOInjector.addDylibLoad(dylib.lastPathComponent, to: executable)
            onLog("▸ 已注入 LC_LOAD_DYLIB：\(outcome.loadPath)（\(outcome.injectedBytes) 字节）")
            if outcome.clearedSignature {
                onLog("⚠️ 原代码签名已失效，安装前必须用 ldid 重签。")
            }
        } catch {
            throw ShellError.injectFailed(error.localizedDescription)
        }

        // 注入清掉了原签名，就地补回去：ldid 写 entitlements，codex-sign 补
        // App Store 形态的 CodeDirectory（只做 ldid 会被 AMFI 杀掉）。
        // 工具不可用时保持 needsResign = true，并把原因写进日志，不假装签好。
        let signing = RuntimeSigner.signArtifacts(paths: [executable, dylibTarget])
        var needsResign = true
        switch signing.status {
        case .signed:
            needsResign = false
            onLog("▸ 已重签主二进制与注入的 dylib（ldid + codex-sign，\(signing.signedCount) 个）")
        case .adhocOnly:
            onLog("⚠️ 只做了 adhoc 签名（缺 codex-sign）：安装后可能被 AMFI 杀掉（Bad executable / Killed: 9）。")
        case .skipped:
            onLog("⚠️ 未重签：\(signing.reason ?? AppLocalized("signing unavailable"))")
        case .failed:
            onLog("⚠️ 重签失败：\(signing.reason ?? "")")
        }

        // Repackage.
        onLog("▸ 重新打包…")
        try? fm.removeItem(at: output)
        let writer: BackupZipWriter
        do {
            writer = try BackupZipWriter(url: output)
        } catch {
            throw ShellError.writeFailed(error.localizedDescription)
        }
        var entries: [(source: URL, name: String)] = []
        let enumerator = fm.enumerator(at: payload, includingPropertiesForKeys: [.isRegularFileKey]) ?? nil
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let name = "Payload/" + item.path.replacingOccurrences(of: payload.path + "/", with: "")
            entries.append((source: item, name: name))
        }
        do {
            try writer.addFiles(entries)
            try writer.close()
        } catch {
            throw ShellError.writeFailed(error.localizedDescription)
        }
        onLog("▸ 打壳完成：\(output.lastPathComponent)（\(entries.count) 个文件）")
        logger.notice("IPA shell packed: \(output.lastPathComponent), dylib=\(dylib.lastPathComponent)")

        return Outcome(ipa: output, appPath: app.path, executable: executable.path,
                       injectedDylib: dylibTarget.path, needsResign: needsResign,
                       signing: signing)
    }

    /// Newest `.dylib` under `projectPath` (prefers `.theos/obj`, falls back
    /// to the project root). Used when the caller does not name one.
    static func findBuiltDylib(in projectPath: String) -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: projectPath, isDirectory: true)
        var found: [(URL, Date)] = []
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "dylib" else { continue }
            if item.path.contains("/.git/") { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            found.append((item, date))
        }
        return found.max(by: { $0.1 < $1.1 })?.0
    }
}
