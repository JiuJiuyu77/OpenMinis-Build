//
//  NativeCommandRunner.swift
//  Minis — 原生进程执行（不经过 iSH 的 Linux 模拟层）
//
//  posix_spawn + 管道读取，逐行回调；支持超时与取消（整组 SIGTERM → SIGKILL）。
//  与 iSH 路径的语义差别：这里跑在真实文件系统上，路径就是设备绝对路径。
//

import Foundation

enum NativeCommandRunner {

    struct Result {
        var output: String
        var exitCode: Int32
        var duration: TimeInterval
        var timedOut: Bool
        var ok: Bool { exitCode == 0 && !timedOut }
    }

    private static let queue = DispatchQueue(label: "app.minis.native-build.runner", qos: .userInitiated)

    /// Why spawning failed, in words a user can act on. `posix_spawn` answers
    /// with an errno; "no-sandbox permission" was only ever a guess, and it is
    /// wrong for the two cases we actually hit: a shell whose `@rpath` dylibs
    /// do not resolve (dyld kills the child) and a binary the kernel refuses
    /// to exec because it is not signed.
    static func describeSpawnFailure(_ code: Int32) -> String {
        switch code {
        case EPERM:
            return "posix_spawn EPERM — the kernel refused to exec the shell. The app lacks no-sandbox / platform-application, or the shell binary is unsigned. Re-sign the app (and the runtime) with the TrollStore entitlements."
        case ENOENT:
            return "posix_spawn ENOENT — the shell path does not exist any more. Reinstall the Theos runtime."
        case EACCES:
            return "posix_spawn EACCES — the shell is not executable (missing +x, or the mount is noexec)."
        case E2BIG:
            return "posix_spawn E2BIG — the environment is too large (too many / too long env vars)."
        case ENOMEM:
            return "posix_spawn ENOMEM — out of memory while forking. Close other apps and retry."
        // 8 ENOEXEC / 85 EBADEXEC / 86 EBADARCH / 87 ESHLIBVERS / 88 EBADMACHO
        // iOS 上这几个基本只有三种成因：二进制没签名（amfid 拒），依赖的 dylib
        // 解析不到（dyld 打死子进程），或者架构/文件本身坏了。以前它们全落到
        // default 分支，只显示 "Bad executable"，等于什么都没说。
        case 8, 85, 86, 87, 88:
            return "posix_spawn EBADEXEC — 内核或 dyld 拒绝执行这个二进制。三种常见成因：\n"
                + "        1) 二进制没有有效代码签名（TrollStore 下需要 adhoc/ldid 重签）\n"
                + "        2) 它依赖的 dylib 找不到（Theos 运行时的 usr/lib 不在搜索路径里）\n"
                + "        3) 架构不符或文件下载不完整\n"
                + "        注意：如果诊断显示文件只有几十字节（截断的残骸），那就是运行时损坏，\n"
                + "        沙盒是独立 chroot，既看不见设备侧的运行时目录也没有写权限，无法就地重建；\n"
                + "        必须到 设置 → 运行时诊断 重装该运行时。"
        case 0:
            return "posix_spawn succeeded but returned no pid."
        default:
            return "posix_spawn failed (errno \(code): \(String(cString: strerror(code))))."
        }
    }

    /// Shells to try, best first. The Theos runtime ships a zsh whose `@rpath`
    /// dylibs live in the runtime's own `usr/lib`; a jailbreak's own bash is
    /// the next best. Trying one shell and giving up turned an rpath problem
    /// into "no-sandbox permission", which sent users hunting the wrong fix.
    static func shellCandidates() -> [String] {
        var out: [String] = []
        if let primary = NativeToolchain.shared.shellPath { out.append(primary) }
        out.append(contentsOf: NativeToolchain.allShellCandidates())
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 单引号安全转义（与 sh 一致）。
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 运行一条命令。
    /// - Parameters:
    ///   - command: shell 脚本（会交给 shell -lc 执行）
    ///   - directory: 工作目录
    ///   - environment: 子进程环境
    ///   - timeout: 超时秒数（<=0 表示不限）
    ///   - onLine: 每读到一行调用一次（在后台队列上）
    static func run(command: String,
                    in directory: String?,
                    environment: [String: String],
                    timeout: TimeInterval,
                    onLine: ((String) -> Void)? = nil,
                    onSpawn: ((pid_t) -> Void)? = nil) async -> Result {
        let started = Date()
        let script: String
        if let directory, !directory.isEmpty {
            script = "cd " + shellQuote(directory) + " || exit 96\n" + command
        } else {
            script = command
        }

        var envPairs: [String] = []
        // [T-exec-dyld-path] Theos 运行时把 zsh 依赖的 dylib 放在自己的 usr/lib，
        // 而二进制里记的往往是构建机上的 @rpath。补上 DYLD 回退路径，能直接救回
        // 「库其实在、只是找不到」这一类 EBADEXEC，不必让用户手工 export。
        var environment = environment
        do {
            var dirs: [String] = []
            for shell in shellCandidates() {
                let bin = (shell as NSString).deletingLastPathComponent
                let prefix = (bin as NSString).deletingLastPathComponent
                let root = (prefix as NSString).deletingLastPathComponent
                if !bin.isEmpty { dirs.append(bin) }
                if !prefix.isEmpty { dirs.append("\(prefix)/lib") }
                if !root.isEmpty { dirs.append("\(root)/lib") }
            }
            let joined = dirs.joined(separator: ":")
            if !joined.isEmpty {
                if let existing = environment["DYLD_FALLBACK_LIBRARY_PATH"], !existing.isEmpty {
                    environment["DYLD_FALLBACK_LIBRARY_PATH"] = "\(existing):\(joined)"
                } else {
                    environment["DYLD_FALLBACK_LIBRARY_PATH"] = joined
                }
            }
        }

        for (key, value) in environment where !key.contains("=") {
            envPairs.append("\(key)=\(value)")
        }

        // Try each candidate shell in turn. A child that dies inside dyld
        // (because `@rpath/libiosexec.1.dylib` does not resolve) reports
        // EPERM/ENOENT from posix_spawn exactly like a sandbox denial, so a
        // single attempt both hides the real cause and gives up too early.
        var lastErrno: Int32 = 0
        // [T-spawn-per-shell-errno] 每个候选 shell 的失败原因要单独留着。
        // 之前只保存最后的 errno，而最终报告又把所有候选一起列出来，看起来
        // 像「每个 shell 都报同一个错」——实际常常是：主 shell 因 dyld/@rpath
        // 解析失败返回 ENOENT，备用 shell 因权限返回 EPERM。混成一个 errno
        // 会把排查引到错误的方向（例如让人去改 entitlements）。
        var spawnFailures: [(shell: String, code: Int32)] = []
        var spawnedPid: pid_t = -1
        var readFD: Int32 = -1
        for shell in shellCandidates() {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            var outPipe: [Int32] = [-1, -1]
            guard pipe(&outPipe) == 0 else {
                return Result(output: "无法创建管道", exitCode: -1, duration: 0, timedOut: false)
            }

            var actions: posix_spawn_file_actions_t? = nil
            posix_spawn_file_actions_init(&actions)
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 2)
            posix_spawn_file_actions_addclose(&actions, outPipe[0])
            posix_spawn_file_actions_addclose(&actions, outPipe[1])

            var attr: posix_spawnattr_t? = nil
            posix_spawnattr_init(&attr)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
            posix_spawnattr_setpgroup(&attr, 0)
            var defaults = sigset_t()
            sigemptyset(&defaults)
            posix_spawnattr_setsigdefault(&attr, &defaults)

            let argv: [String] = [shell, "-lc", script]
            let (child, rc) = await withCheckedContinuation {
                (cont: CheckedContinuation<(pid_t, Int32), Never>) in
                queue.async {
                    var child: pid_t = -1
                    let rc = runSpawn(&child, shell, argv, envPairs, &actions, &attr)
                    posix_spawn_file_actions_destroy(&actions)
                    posix_spawnattr_destroy(&attr)
                    cont.resume(returning: (child, rc))
                }
            }
            close(outPipe[1])
            if rc == 0 && child > 0 {
                spawnedPid = child
                readFD = outPipe[0]
                break
            }
            // posix_spawn 直接返回错误码，不要读 errno（它未必被设置）。
            let failureCode = rc == 0 ? errno : rc
            lastErrno = failureCode
            spawnFailures.append((shell: shell, code: failureCode))
            close(outPipe[0])
        }

        guard spawnedPid > 0 else {
            let detail = describeSpawnFailure(lastErrno)
            // 逐条给出每个候选的真实结局：失败原因 / 未尝试 / 不可执行。
            let tried = shellCandidates().map { path -> String in
                if let failure = spawnFailures.first(where: { $0.shell == path }) {
                    return "\(path) → \(describeSpawnFailure(failure.code))\n      \(diagnoseExecutable(path))"
                }
                if FileManager.default.isExecutableFile(atPath: path) {
                    return "\(path) → not attempted"
                }
                return "\(path) → missing or not executable"
            }.joined(separator: "\n  ")
            return Result(output: """
            Could not start a process. Every candidate shell failed.
            \(detail)
            Shells tried:
              \(tried)
            Diagnostics: Settings → Executor → Toolchain diagnostics (the Shell row shows which shell was picked), \
            or Settings → Developer Runtime → runtimes (reinstall Theos if the runtime is incomplete).
            """,
                          exitCode: -1, duration: Date().timeIntervalSince(started), timedOut: false)
        }
        let pid = spawnedPid
        let outPipe = [readFD, Int32(-1)]
        onSpawn?(pid)

        let collector = LineCollector(onLine: onLine)
        let reader = DispatchQueue(label: "app.minis.native-build.reader")
        let finished = DispatchSemaphore(value: 0)

        reader.async {
            let handle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                collector.append(data)
            }
            finished.signal()
        }

        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : Date.distantFuture
        var timedOut = false
        var status: Int32 = 0

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                while true {
                    var st: Int32 = 0
                    let r = waitpid(pid, &st, WNOHANG)
                    if r == pid {
                        status = st
                        break
                    }
                    if r < 0 && errno != EINTR { break }
                    if Date() > deadline {
                        timedOut = true
                        kill(-pid, SIGTERM)
                        usleep(800_000)
                        kill(-pid, SIGKILL)
                        _ = waitpid(pid, &st, 0)
                        status = st
                        break
                    }
                    usleep(120_000)
                }
                cont.resume()
            }
        }

        _ = finished.wait(timeout: .now() + 2)
        collector.flush()

        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(output: collector.text,
                      exitCode: code,
                      duration: Date().timeIntervalSince(started),
                      timedOut: timedOut)
    }

    private static func runSpawn(_ child: inout pid_t,
                                 _ executable: String,
                                 _ args: [String],
                                 _ env: [String],
                                 _ actions: inout posix_spawn_file_actions_t?,
                                 _ attr: inout posix_spawnattr_t?) -> Int32 {
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cArgs.append(nil)
        cEnv.append(nil)
        defer {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
        }
        return executable.withCString { path in
            posix_spawn(&child, path, &actions, &attr, &cArgs, &cEnv)
        }
    }
}

/// 把字节流按行切分，避免多字节字符被截断。
private final class LineCollector {
    private var buffer = Data()
    private var pending = ""
    private var all = ""
    private let onLine: ((String) -> Void)?
    private let lock = NSLock()

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        buffer.removeAll(keepingCapacity: true)
        pending += text
        while let idx = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<idx])
            pending = String(pending[pending.index(after: idx)...])
            emit(line)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty {
            emit(pending)
            pending = ""
        }
        if let rest = String(data: buffer, encoding: .isoLatin1), !rest.isEmpty {
            emit(rest)
            buffer.removeAll()
        }
    }

    private func emit(_ line: String) {
        all += line + "\n"
        onLine?(line)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return all
    }

}

/// 见 NativeCommandRunner 的 EBADEXEC 诊断。放在文件作用域，
/// 供 runner 与其它诊断入口共用。
/// 读 Mach-O 头，回答「这个文件到底是什么」：架构、有没有代码签名、多大。
/// EBADEXEC 时把这三种成因区分开——「未签名」要重签，「缺 dylib」要补路径，
/// 两者解法完全不同，混在一起只会让人乱试。
private func diagnoseExecutable(_ path: String) -> String {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path) else {
        return "诊断：文件不存在"
    }
    let size = (attrs[.size] as? Int) ?? 0
    var notes: [String] = ["\(size) 字节", fm.isExecutableFile(atPath: path) ? "有执行位" : "缺执行位"]
    guard let fh = FileHandle(forReadingAtPath: path) else {
        return "诊断：" + notes.joined(separator: "、")
    }
    defer { try? fh.close() }
    let head = [UInt8](fh.readData(ofLength: 65536))
    guard head.count >= 32 else {
        return "诊断：" + notes.joined(separator: "、") + "、文件过短（可能下载不完整）"
    }
    func u32(_ o: Int) -> UInt32 {
        guard o + 3 < head.count else { return 0 }
        return UInt32(head[o]) | (UInt32(head[o + 1]) << 8)
            | (UInt32(head[o + 2]) << 16) | (UInt32(head[o + 3]) << 24)
    }
    let magic = u32(0)
    guard magic == 0xFEED_FACF || magic == 0xFEED_FACE || magic == 0xCAFE_BABE else {
        notes.append("不是 Mach-O（magic 0x" + String(magic, radix: 16) + "）")
        return "诊断：" + notes.joined(separator: "、")
    }
    let cpu = u32(4)
    switch cpu {
    case 0x0100_000C: notes.append("arm64")
    case 0x0100_0007: notes.append("x86_64（架构不符）")
    case 0x0000_000C: notes.append("armv7（架构不符）")
    default: notes.append("cpu 0x" + String(cpu, radix: 16))
    }
    let ncmds = Int(u32(16))
    var idx = 32
    var hasSignature = false
    for _ in 0..<max(0, ncmds) {
        guard idx + 8 <= head.count else { break }
        let cmd = u32(idx)
        let cmdsize = Int(u32(idx + 4))
        if cmd == 0x1D { hasSignature = true; break }
        if cmdsize <= 0 { break }
        idx += cmdsize
    }
    notes.append(hasSignature ? "带代码签名" : "无代码签名（需要 ldid 重签）")
    return "诊断：" + notes.joined(separator: "、")
}

/// 运行时二进制的完整性检查：截断的残骸（几十字节）或根本不是 Mach-O 都算损坏。
/// 返回 nil 表示看起来正常。沙盒是独立 chroot，坏了没法在沙盒里重建，
/// 只能由 App 侧删掉损坏目录再重装。
func runtimeBinaryDamage(_ path: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return "文件不存在" }
    let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    guard size >= 4096 else { return "只有 \(size) 字节——下载被截断的残骸" }
    guard let fh = FileHandle(forReadingAtPath: path) else { return "无法读取" }
    defer { try? fh.close() }
    let head = [UInt8](fh.readData(ofLength: 4))
    guard head.count == 4 else { return "文件过短" }
    let magic = UInt32(head[0]) | (UInt32(head[1]) << 8) | (UInt32(head[2]) << 16) | (UInt32(head[3]) << 24)
    guard magic == 0xFEED_FACF || magic == 0xFEED_FACE else {
        return "不是 Mach-O（magic 0x" + String(magic, radix: 16) + "）"
    }
    return nil
}
