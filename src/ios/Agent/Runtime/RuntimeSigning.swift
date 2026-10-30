//
//  RuntimeSigning.swift
//  Minis — 运行时二进制的签名层（ldid → minis-sign）
//
//  背景：装好的运行时里全是 Mach-O（clang、ld64、bash、NodeMobile.framework…）。
//  只把文件落到磁盘是不够的，iOS 要真的执行它们，签名必须满足两层：
//
//    1. ldid -S<entitlements>   写入 entitlements + adhoc 签名；
//    2. minis-sign              在 adhoc 签名之上补 App Store 形态的 CodeDirectory
//                               （TeamID + cdhashes），否则 AMFI 不认这个结构，
//                               表现为 Bad executable / Killed: 9。
//
//  只做第 1 步是「签名残缺」：dlopen/posix_spawn 能过一部分检查，但一执行就被杀。
//  minis-sign 是 App 自带工具（`Helpers/minis-sign`，TrollStore 的 CoreTrust 路径），
//  ldid 由 Theos 运行时提供。
//
//  权限来源：不硬编码一份 plist，而是从本进程的签名里挑出「让子进程可执行」的那几条
//  （platform-application / no-sandbox / task_for_pid-allow …）。App 自己不是以这些
//  权限签名时（App Store / 普通侧载），签了也没意义 —— 直接报 skipped，而不是假装成功。
//

import Darwin
import Foundation

/// 一次签名作业的结论。
struct RuntimeSignReport: Codable, Equatable {
    enum Status: String, Codable {
        /// 全部目标都过了 ldid + minis-sign。
        case signed
        /// 只有 adhoc 签名（本机没有 minis-sign），能过一部分检查但可能被 AMFI 杀掉。
        case adhocOnly
        /// 不需要 / 无法签名（沙盒环境、或该运行时没有 sign_paths）。
        case skipped
        /// 有目标签名失败。
        case failed
    }

    let status: Status
    /// 实际执行到的最大深度。
    let mode: String?
    let signedCount: Int
    let failedPaths: [String]
    let reason: String?
    let ldidPath: String?
    let minisSignPath: String?
    let checkedAt: Date

    var isAcceptable: Bool { status != .failed }

    var shortSummary: String {
        switch status {
        case .signed:
            return AppLocalized("Signed (ldid + minis-sign)") + " · \(signedCount)"
        case .adhocOnly:
            return AppLocalized("Ad-hoc signed only") + (reason.map { " · \($0)" } ?? "")
        case .skipped:
            return AppLocalized("Signing skipped") + (reason.map { " · \($0)" } ?? "")
        case .failed:
            return AppLocalized("Signing failed") + (reason.map { " · \($0)" } ?? "")
        }
    }

    static func failed(_ reason: String, paths: [String] = [],
                       ldid: String? = nil, codex: String? = nil) -> RuntimeSignReport {
        RuntimeSignReport(status: .failed, mode: nil, signedCount: 0, failedPaths: paths,
                          reason: reason, ldidPath: ldid, minisSignPath: codex, checkedAt: Date())
    }
}

enum RuntimeSigner {

    /// 让子进程能真正执行的那几条权限。取自运行中的 App 自身签名，不凭空构造：
    /// 只有 App 已经带着它们（TrollStore / 越狱签名）时，签出来的运行时二进制才有意义。
    static let propagatedEntitlementKeys = [
        "platform-application",
        "com.apple.private.security.no-sandbox",
        "com.apple.private.security.no-container",
        "com.apple.private.security.storage.AppBundles",
        "com.apple.private.security.storage.AppDataContainers",
        "task_for_pid-allow",
        "get-task-allow",
        "proc_info-allow",
    ]

    // MARK: - 签名入口

    /// 给一个刚解包到 `root` 的运行时签名。
    ///
    /// - Parameter canExecuteNative: 沙盒环境下连 ldid 都起不来，直接 skipped。
    static func signRuntime(descriptor: RuntimeDescriptor,
                            root: URL,
                            canExecuteNative: Bool,
                            timeout: TimeInterval = 180) -> RuntimeSignReport {
        let spec = descriptor.installSpecOrNone
        let targets = spec.signTargets(in: root)
        let declaredEntitlementsTargets = targets.entitlements.map { root.appendingPathComponent($0) }
        let declaredAdhocTargets = targets.adhoc.map { root.appendingPathComponent($0) }
        let declared = Set((declaredEntitlementsTargets + declaredAdhocTargets).map(\.standardizedFileURL.path))
        let discovered = discoverMachOFiles(in: root)
            .filter { !declared.contains($0.standardizedFileURL.path) }
        let discoveredAdhocTargets = discovered.filter { isDylibOrFramework($0) }
        let discoveredEntitlementsTargets = discovered.filter { !isDylibOrFramework($0) }
        let entitlementsTargets = declaredEntitlementsTargets + discoveredEntitlementsTargets
        let adhocTargets = declaredAdhocTargets + discoveredAdhocTargets

        guard !entitlementsTargets.isEmpty || !adhocTargets.isEmpty else {
            return RuntimeSignReport(status: .skipped, mode: nil, signedCount: 0, failedPaths: [],
                                     reason: AppLocalized("This runtime declares no binaries to sign."),
                                     ldidPath: nil, minisSignPath: nil, checkedAt: Date())
        }
        guard canExecuteNative else {
            return RuntimeSignReport(status: .skipped, mode: nil, signedCount: 0, failedPaths: [],
                                     reason: AppLocalized("Cannot run the signing tools in this environment."),
                                     ldidPath: nil, minisSignPath: nil, checkedAt: Date())
        }
        let ldid = locateLdid()
        let minisSign = locateMinisSign()
        guard ldid != nil || minisSign != nil else {
            return .failed(AppLocalized("Neither ldid nor minis-sign was found."))
        }
        guard let entitlements = entitlementsPlist() else {
            return .failed(AppLocalized("This app is not signed with native entitlements, so runtime binaries cannot be made executable."),
                           ldid: ldid?.path)
        }

        var signed = 0
        var failed: [String] = []
        var lastOutput = ""
        let plistURL = writeTemporaryPlist(entitlements)

        for target in entitlementsTargets + adhocTargets {
            let isAdhocOnly = adhocTargets.contains(target)
            guard isMachO(target) else { continue }
            let name = target.lastPathComponent

            // 1. 第一段签名：优先 ldid（能写 entitlements）；Theos 运行时的 ldid
            //    自己也可能还没签名（引导期），那就让 minis-sign 先做一次 adhoc。
            var adhocDone = false
            if let ldid {
                let ldidArguments = isAdhocOnly || entitlements.isEmpty
                    ? ["-S", target.path]
                    : ["-S" + (plistURL?.path ?? ""), target.path]
                let ldidResult = RuntimeProbeRunner.run(executable: ldid.path,
                                                        arguments: ldidArguments,
                                                        environment: ProcessInfo.processInfo.environment,
                                                        workingDirectory: root.path,
                                                        timeout: timeout)
                lastOutput = ldidResult.output
                adhocDone = ldidResult.spawnError == nil && ldidResult.status == 0
            }
            if !adhocDone, let minisSign {
                let bootstrap = RuntimeProbeRunner.run(executable: minisSign.path,
                                                       arguments: ["--adhoc-only", target.path],
                                                       environment: ProcessInfo.processInfo.environment,
                                                       workingDirectory: root.path,
                                                       timeout: timeout)
                lastOutput = bootstrap.output
                adhocDone = bootstrap.spawnError == nil && bootstrap.status == 0
            }
            if !adhocDone {
                failed.append(name)
                continue
            }

            // 2. minis-sign：补 App Store 形态的 CodeDirectory。
            guard let minisSign else {
                signed += 1 // adhoc 已成功，整体降级为 adhocOnly
                continue
            }
            var codexArguments: [String] = []
            if isAdhocOnly {
                codexArguments.append("--adhoc-only")
            } else if let plistURL {
                codexArguments.append(contentsOf: ["--entitlements", plistURL.path])
            }
            codexArguments.append(target.path)
            let codexResult = RuntimeProbeRunner.run(executable: minisSign.path,
                                                     arguments: codexArguments,
                                                     environment: ProcessInfo.processInfo.environment,
                                                     workingDirectory: root.path,
                                                     timeout: timeout)
            lastOutput = codexResult.output
            if codexResult.spawnError != nil || codexResult.status != 0 {
                failed.append(name)
                continue
            }
            signed += 1
        }

        if let plistURL { try? FileManager.default.removeItem(at: plistURL) }

        if !failed.isEmpty {
            let snippet = lastOutput.split(separator: "\n").suffix(3).joined(separator: " | ")
            return RuntimeSignReport(status: .failed, mode: minisSign == nil ? "ldid" : "ldid+minis-sign",
                                     signedCount: signed, failedPaths: failed,
                                     reason: snippet.isEmpty
                                        ? AppLocalized("Signing failed.")
                                        : String(snippet.prefix(400)),
                                     ldidPath: ldid?.path, minisSignPath: minisSign?.path, checkedAt: Date())
        }
        let mode = minisSign == nil ? "ldid" : "ldid+minis-sign"
        let status: RuntimeSignReport.Status = minisSign == nil ? .adhocOnly : .signed
        return RuntimeSignReport(status: status, mode: mode, signedCount: signed, failedPaths: [],
                                 reason: minisSign == nil
                                    ? AppLocalized("minis-sign is not bundled, so the App Store-style CodeDirectory is missing.")
                                    : nil,
                                 ldidPath: ldid?.path, minisSignPath: minisSign?.path, checkedAt: Date())
    }

    /// 给**构建产物**签名（NativeBuild 的 dylib / 打壳后的 App 主二进制）。
    ///
    /// 与装运行时不同：这里没有清单条目可依，签名深度由调用方决定 ——
    /// 编出来的 dylib 需要完整 CodeDirectory 才能被 dyld 接受，而注入过的
    /// App 主二进制同理（注入会清掉原签名）。
    static func signArtifacts(paths: [URL],
                              adhocOnly: Bool = false,
                              canExecuteNative: Bool? = nil,
                              timeout: TimeInterval = 180) -> RuntimeSignReport {
        let executableHost = canExecuteNative
            ?? MinisHostEnvironmentDetector.cached.canRunNativeBinaries
        let targets = paths.filter { isMachO($0) }
        guard !targets.isEmpty else {
            return RuntimeSignReport(status: .skipped, mode: nil, signedCount: 0, failedPaths: [],
                                     reason: AppLocalized("No Mach-O output to sign."),
                                     ldidPath: nil, minisSignPath: nil, checkedAt: Date())
        }
        guard executableHost else {
            return RuntimeSignReport(status: .skipped, mode: nil, signedCount: 0, failedPaths: [],
                                     reason: AppLocalized("Cannot run the signing tools in this environment."),
                                     ldidPath: nil, minisSignPath: nil, checkedAt: Date())
        }
        guard let ldid = locateLdid() else {
            return RuntimeSignReport(status: .skipped, mode: nil, signedCount: 0, failedPaths: [],
                                     reason: AppLocalized("ldid was not found. Install the Theos runtime first."),
                                     ldidPath: nil, minisSignPath: nil, checkedAt: Date())
        }
        let minisSign = locateMinisSign()
        let entitlements = adhocOnly ? nil : entitlementsPlist()
        let plistURL = entitlements.flatMap(writeTemporaryPlist)
        defer { if let plistURL { try? FileManager.default.removeItem(at: plistURL) } }

        var signed = 0
        var failed: [String] = []
        var lastOutput = ""
        for target in targets {
            let ldidArguments = (adhocOnly || plistURL == nil)
                ? ["-S", target.path]
                : ["-S" + (plistURL?.path ?? ""), target.path]
            let ldidResult = RuntimeProbeRunner.run(executable: ldid.path,
                                                    arguments: ldidArguments,
                                                    environment: ProcessInfo.processInfo.environment,
                                                    workingDirectory: target.deletingLastPathComponent().path,
                                                    timeout: timeout)
            lastOutput = ldidResult.output
            if ldidResult.spawnError != nil || ldidResult.status != 0 {
                failed.append(target.lastPathComponent)
                continue
            }
            if let minisSign {
                var arguments: [String] = []
                if adhocOnly {
                    arguments.append("--adhoc-only")
                } else if let plistURL {
                    arguments.append(contentsOf: ["--entitlements", plistURL.path])
                }
                arguments.append(target.path)
                let codexResult = RuntimeProbeRunner.run(executable: minisSign.path,
                                                         arguments: arguments,
                                                         environment: ProcessInfo.processInfo.environment,
                                                         workingDirectory: target.deletingLastPathComponent().path,
                                                         timeout: timeout)
                lastOutput = codexResult.output
                if codexResult.spawnError != nil || codexResult.status != 0 {
                    failed.append(target.lastPathComponent)
                    continue
                }
            }
            signed += 1
        }
        if !failed.isEmpty {
            return RuntimeSignReport(status: .failed, mode: minisSign == nil ? "ldid" : "ldid+minis-sign",
                                     signedCount: signed, failedPaths: failed,
                                     reason: String(lastOutput.split(separator: "\n").suffix(3)
                                                    .joined(separator: " | ").prefix(400)),
                                     ldidPath: ldid.path, minisSignPath: minisSign?.path, checkedAt: Date())
        }
        return RuntimeSignReport(status: minisSign == nil ? .adhocOnly : .signed,
                                 mode: minisSign == nil ? "ldid" : "ldid+minis-sign",
                                 signedCount: signed, failedPaths: [],
                                 reason: minisSign == nil
                                    ? AppLocalized("minis-sign is not bundled, so the App Store-style CodeDirectory is missing.")
                                    : nil,
                                 ldidPath: ldid.path, minisSignPath: minisSign?.path, checkedAt: Date())
    }

    // MARK: - 工具定位

    /// `minis-sign` 由 App 自带（`Helpers/minis-sign`）；运行时目录里也允许放一份。
    static func locateMinisSign() -> URL? {
        let fm = FileManager.default
        var candidates = [Bundle.main.bundleURL.appendingPathComponent("Helpers/minis-sign")]
        for root in installedRuntimeRoots() {
            candidates.append(root.appendingPathComponent("Helpers/minis-sign"))
            candidates.append(root.appendingPathComponent("bin/minis-sign"))
            candidates.append(root.appendingPathComponent("usr/bin/minis-sign"))
        }
        // 不重新打包也能用：把 minis-sign 丢进 App 的 Application Support 即可。
        candidates.append(DeveloperRuntimePaths.root.appendingPathComponent("Helpers/minis-sign"))
        candidates.append(URL(fileURLWithPath: "/var/jb/usr/bin/minis-sign"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/minis-sign"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// `ldid` 由 Theos 运行时提供（`usr/bin/ldid` 或 `bin/ldid`）。
    static func locateLdid() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for root in installedRuntimeRoots() {
            candidates.append(root.appendingPathComponent("usr/bin/ldid"))
            candidates.append(root.appendingPathComponent("bin/ldid"))
            candidates.append(root.appendingPathComponent("theos/toolchain/linux/iphone/bin/ldid"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Helpers/ldid"))
        candidates.append(URL(fileURLWithPath: "/var/jb/usr/bin/ldid"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ldid"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private static func installedRuntimeRoots() -> [URL] {
        let fm = FileManager.default
        let base = DeveloperRuntimePaths.installedRoot
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    // MARK: - entitlements

    /// 从本进程签名里挑出可传播的 entitlements；一条都没有时返回 nil。
    static func entitlementsPlist() -> [String: Any]? {
        // 构建里可以放一份固定的 plist 覆盖探测结果（Configs/NativeSigning.entitlements）。
        if let bundled = Bundle.main.url(forResource: "NativeSigning", withExtension: "entitlements"),
           let data = try? Data(contentsOf: bundled),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           !parsed.isEmpty {
            return parsed
        }
        guard let task = secTaskCreateFromSelf() else { return nil }
        var result: [String: Any] = [:]
        for key in propagatedEntitlementKeys {
            guard let value = secTaskCopyEntitlement(task, key) else { continue }
            if let number = value as? NSNumber {
                if number.boolValue { result[key] = true }
            } else if let bool = value as? Bool {
                if bool { result[key] = true }
            } else if let string = value as? String, !string.isEmpty {
                result[key] = string
            } else if let array = value as? [String], !array.isEmpty {
                result[key] = array
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func writeTemporaryPlist(_ entitlements: [String: Any]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-entitlements-\(UUID().uuidString).plist")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entitlements,
                                                             format: .xml, options: 0) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Mach-O

    /// 目标是不是 Mach-O（thin 或 fat）。非 Mach-O 静默跳过：`sign_paths`
    /// 有时会包含脚本或软链。
    private static let machoMagics: Set<[UInt8]> = [
        [0xcf, 0xfa, 0xed, 0xfe], // 64-bit LE (arm64 / x86_64)
        [0xce, 0xfa, 0xed, 0xfe], // 32-bit LE
        [0xfe, 0xed, 0xfa, 0xcf], // 64-bit BE
        [0xfe, 0xed, 0xfa, 0xce], // 32-bit BE
        [0xca, 0xfe, 0xba, 0xbe], // universal / fat
        [0xca, 0xfe, 0xba, 0xbf], // universal / fat64
    ]

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return machoMagics.contains([UInt8](magic))
    }

    private static func discoverMachOFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  isMachO(url) else { return nil }
            return url
        }
    }

    private static func isDylibOrFramework(_ url: URL) -> Bool {
        let path = url.path
        return url.pathExtension == "dylib"
            || path.contains(".framework/")
            || path.hasSuffix(".framework")
    }

    // MARK: - SecTask（dlsym，避免 Security 私有头）

    private typealias SecTaskRef = CFTypeRef
    private typealias CreateFromSelfFn = @convention(c) (CFAllocator?) -> SecTaskRef?
    private typealias CopyValueFn = @convention(c) (SecTaskRef?, CFString,
                                                    UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    private static func secTaskCreateFromSelf() -> SecTaskRef? {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "SecTaskCreateFromSelf") else { return nil }
        let function = unsafeBitCast(symbol, to: CreateFromSelfFn.self)
        return function(nil)
    }

    private static func secTaskCopyEntitlement(_ task: SecTaskRef?, _ key: String) -> Any? {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return nil }
        let function = unsafeBitCast(symbol, to: CopyValueFn.self)
        guard let value = function(task, key as CFString, nil) else { return nil }
        return value as Any
    }
}
