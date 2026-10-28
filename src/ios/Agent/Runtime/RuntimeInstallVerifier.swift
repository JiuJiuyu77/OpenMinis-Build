//
//  RuntimeInstallVerifier.swift
//  Minis — 运行时装完自检（required_paths + probe）
//
//  清单的 `install.probe` 是「这个运行时真的能用」的离线断言：
//    { "executable": "bin/git", "arguments": ["--version"], "contains": "git version 2.39.1" }
//  以前装完直接写记录，于是缺 devkit、缺 framework、bin 里只有半个工具的树也算装好。
//  这里在 staging 里先跑一遍：路径闸门 + 真实 spawn 一次 probe。
//
//  三种结果，语义不同，不能混：
//    * passed    —— 路径齐、probe 输出命中标记；
//    * skipped   —— 路径齐，但当前环境不能执行 Mach-O（App 沙盒/侧载），
//                   记录原因，安装照旧成功，UI 显示「未自检」；
//    * failed    —— 路径缺项 / probe 起不来 / 输出不匹配，属于坏包，安装失败。
//

import Darwin
import Foundation

/// 一次自检的结论。
struct RuntimeVerificationReport: Codable, Equatable {
    enum Status: String, Codable {
        case passed
        case skipped
        case failed
    }

    let status: Status
    /// 缺失的 required_paths。
    let missingPaths: [String]
    /// probe 的退出码（起不来时为 nil）。
    let probeExit: Int32?
    /// probe 输出（截断到 4KB，够定位问题）。
    let probeOutput: String?
    /// skipped / failed 的人类可读原因。
    let reason: String?
    let checkedAt: Date

    /// 安装是否可以提交：passed 与 skipped 都可以，failed 不行。
    var isAcceptable: Bool { status != .failed }

    static func passed(probeExit: Int32, output: String) -> RuntimeVerificationReport {
        RuntimeVerificationReport(status: .passed, missingPaths: [], probeExit: probeExit,
                                  probeOutput: output, reason: nil, checkedAt: Date())
    }

    static func skipped(reason: String, probeExit: Int32? = nil) -> RuntimeVerificationReport {
        RuntimeVerificationReport(status: .skipped, missingPaths: [], probeExit: probeExit,
                                  probeOutput: nil, reason: reason, checkedAt: Date())
    }

    static func failed(missing: [String] = [], probeExit: Int32? = nil,
                       output: String? = nil, reason: String) -> RuntimeVerificationReport {
        RuntimeVerificationReport(status: .failed, missingPaths: missing, probeExit: probeExit,
                                  probeOutput: output, reason: reason, checkedAt: Date())
    }

    /// 设置页一行摘要。
    var shortSummary: String {
        switch status {
        case .passed:
            return AppLocalized("Self-check passed")
        case .skipped:
            return AppLocalized("Self-check skipped") + (reason.map { " · \($0)" } ?? "")
        case .failed:
            return AppLocalized("Self-check failed") + (reason.map { " · \($0)" } ?? "")
        }
    }
}

enum RuntimeInstallVerifier {

    /// 在 `root` 上按 `descriptor.install` 做自检。
    /// - Parameter canExecuteNative: 当前环境能否执行设备原生二进制
    ///   （`MinisHostEnvironment.canRunNativeBinaries`）。为 false 时 probe 记为
    ///   skipped，而不是把一份完整但无法在沙盒里运行的树判成坏包。
    static func verify(descriptor: RuntimeDescriptor,
                       root: URL,
                       canExecuteNative: Bool,
                       timeout: TimeInterval = 60) async -> RuntimeVerificationReport {
        let spec = descriptor.installSpecOrNone
        guard !spec.requiredPaths.isEmpty || spec.probe != nil else {
            // App 自管 handler（codex / theos / python / reverse_tools）没有 install 块。
            return .skipped(reason: AppLocalized("This runtime does not publish a self-check."))
        }

        let missing = spec.missingPaths(in: root)
        guard missing.isEmpty else {
            return .failed(missing: missing,
                           reason: AppLocalized("Archive is incomplete: missing required paths."))
        }

        guard let probe = spec.probe else {
            return .skipped(reason: AppLocalized("No probe declared."))
        }

        guard let executable = RuntimePathPolicy.containedURL(probe.executable, in: root),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failed(reason: AppLocalized("Probe executable is missing or not executable."))
        }
        guard canExecuteNative else {
            return .skipped(reason: AppLocalized("Cannot execute native binaries in this environment."))
        }

        let overlay = RuntimeEnvironmentOverlay.build(descriptor: descriptor, root: root)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overlay.exports { environment[key] = value }
        if let prefix = overlay.pathPrefix {
            let inherited = environment["PATH"] ?? "/usr/bin:/bin"
            environment["PATH"] = prefix + ":" + inherited
        }

        let result = RuntimeProbeRunner.run(executable: executable.path,
                                            arguments: probe.arguments,
                                            environment: environment,
                                            workingDirectory: root.path,
                                            timeout: timeout)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(output.prefix(4096))

        if result.timedOut {
            return .failed(probeExit: result.status, output: snippet,
                           reason: AppLocalized("Probe timed out."))
        }
        if let spawnError = result.spawnError {
            return .failed(probeExit: nil, output: snippet, reason: spawnError)
        }
        guard result.status == 0 else {
            return .failed(probeExit: result.status, output: snippet,
                           reason: AppLocalized("Probe exited with a non-zero status."))
        }
        if let expected = probe.contains, !expected.isEmpty, !output.contains(expected) {
            return .failed(probeExit: result.status, output: snippet,
                           reason: AppLocalized("Probe output did not contain the expected marker."))
        }
        return .passed(probeExit: result.status, output: snippet)
    }
}

/// 用 `posix_spawn` 跑一次命令并收集输出。
///
/// 不能用 `Process`：它不在 iOS 上可用。也不能 `system()`：那会经过 `/bin/sh`，
/// 而 iOS 上 `/bin/sh` 不一定存在（运行时的 Node shim 就是为了这个才重写
/// `child_process` 的默认 shell）。
enum RuntimeProbeRunner {

    struct Result {
        let status: Int32
        let output: String
        let timedOut: Bool
        let spawnError: String?
    }

    /// 读线程与等待循环并发访问输出，用引用类型承载而不是捕获 `var`。
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
        let lock = NSLock()

        func append(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) {
            lock.lock(); defer { lock.unlock() }
            let available = max(0, (1 << 20) - data.count)
            if available > 0 { data.append(buffer, count: min(count, available)) }
        }

        var snapshot: Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    /// The symbol exists on supported iOS runtimes but SDK headers mark the
    /// direct call unavailable. Resolve it explicitly, never chdir the app's
    /// process-wide cwd (other offloads execute concurrently).
    private static func addWorkingDirectory(_ actions: inout posix_spawn_file_actions_t?,
                                            _ directory: String) -> Int32 {
        typealias AddChdir = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t?>, UnsafePointer<CChar>) -> Int32
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(handle, "posix_spawn_file_actions_addchdir_np")
                ?? dlsym(handle, "posix_spawn_file_actions_addchdir") else { return ENOTSUP }
        let function = unsafeBitCast(symbol, to: AddChdir.self)
        return directory.withCString { function(&actions, $0) }
    }

    static func run(executable: String,
                    arguments: [String],
                    environment: [String: String],
                    workingDirectory: String,
                    timeout: TimeInterval) -> Result {
        guard !executable.contains("\0"), !workingDirectory.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            return Result(status: -1, output: "", timedOut: false, spawnError: "Invalid spawn argument or environment")
        }
        var pipefds: [Int32] = [0, 0]
        guard pipe(&pipefds) == 0 else {
            return Result(status: -1, output: "", timedOut: false,
                          spawnError: "pipe() failed")
        }

        defer {
            close(pipefds[0])
            close(pipefds[1])
        }
        _ = fcntl(pipefds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipefds[1], F_SETFD, FD_CLOEXEC)
        var fileActions: posix_spawn_file_actions_t? = nil
        let actionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard actionsStatus == 0 else {
            return Result(status: -1, output: "", timedOut: false, spawnError: "spawn file actions init failed (\(actionsStatus))")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        let actionStatuses = [
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&fileActions, pipefds[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, pipefds[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, pipefds[0]),
            posix_spawn_file_actions_addclose(&fileActions, pipefds[1]),
            addWorkingDirectory(&fileActions, workingDirectory)
        ]
        guard actionStatuses.allSatisfy({ $0 == 0 }) else {
            return Result(status: -1, output: "", timedOut: false, spawnError: "spawn file actions configuration failed")
        }

        var attrs: posix_spawnattr_t? = nil
        let attrsStatus = posix_spawnattr_init(&attrs)
        guard attrsStatus == 0 else {
            return Result(status: -1, output: "", timedOut: false, spawnError: "spawn attributes init failed (\(attrsStatus))")
        }
        defer { posix_spawnattr_destroy(&attrs) }
        let identityStatus = NativeSpawnIdentity.configure(&attrs)
        guard identityStatus == 0 else {
            return Result(status: -1, output: "", timedOut: false,
                          spawnError: "Root persona configuration failed (\(identityStatus)); refusing unprivileged runtime operation")
        }
        // Preserve flags that the shared identity policy may have configured.
        var flags: Int16 = 0
        guard posix_spawnattr_getflags(&attrs, &flags) == 0,
              posix_spawnattr_setflags(&attrs, flags | Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attrs, 0) == 0 else {
            return Result(status: -1, output: "", timedOut: false, spawnError: "spawn process group configuration failed")
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer!) }
            for pointer in envp where pointer != nil { free(pointer!) }
        }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &fileActions, &attrs, argv, envp)
        close(pipefds[1])
        pipefds[1] = -1
        guard spawnStatus == 0 else {
            return Result(status: -1, output: "", timedOut: false,
                          spawnError: "posix_spawn failed (\(String(cString: strerror(spawnStatus))))")
        }

        // 子进程退出后管道才会 EOF，所以在后台线程里读，主流程只负责等与超时。
        let readFD = pipefds[0]
        pipefds[0] = -1 // ownership transfers to the reader
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
        let readerStop = DispatchSemaphore(value: 0)
        let box = OutputBox()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
            defer {
                buffer.deallocate()
                close(readFD)
                readerDone.signal()
            }
            while true {
                let count = Darwin.read(readFD, buffer, 8192)
                if count > 0 {
                    box.append(buffer, count: count)
                } else if count == 0 {
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    if readerStop.wait(timeout: .now() + .milliseconds(20)) == .success { break }
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var exitStatus: Int32 = 0
        var waitError: String?
        var timedOut = false
        while true {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
                break
            }
            if waited == -1 {
                if errno == EINTR { continue }
                exitStatus = -1
                waitError = "waitpid failed (\(String(cString: strerror(errno))))"
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                exitStatus = -1
                break
            }
            usleep(20_000)
        }

        // 被杀掉后管道会 EOF，读线程随之返回；给 2 秒兜底避免卡住安装流程。
        if readerDone.wait(timeout: .now() + 2) == .timedOut {
            readerStop.signal()
            _ = readerDone.wait(timeout: .now() + 1)
        }
        let output = String(decoding: box.snapshot, as: UTF8.self)
        return Result(status: exitStatus, output: output, timedOut: timedOut, spawnError: waitError)
    }
}
