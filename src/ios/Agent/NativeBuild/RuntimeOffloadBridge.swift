//
//  RuntimeOffloadBridge.swift
//  Minis — 让 iSH 里的命令直接调用设备原生运行时工具
//
//  背景：Theos 的 make / clang / ld64 / ldid / dpkg-deb 是 Mach-O 二进制，
//  iSH 的 Alpine 环境跑不了；以前只能整条命令切到「原生执行器」，而原生执行
//  在沙箱里又会死在 libiosexec 上。
//
//  这里沿用 App 已有的 native offload 机制（apple-* / minis-* 那套零字节占位
//  命令）：在 iSH 的 guest 侧注册一个 `minis-runtime` 命令，guest 执行它时由
//  内核把调用交给本类，本类再用 posix_spawn 启动真正的运行时工具，并把
//  guest 的 stdin/stdout/stderr 直接接过去。于是：
//
//      minis-runtime make package
//      minis-runtime clang -c foo.m
//      minis-runtime ldid -S app
//
//  都能在 iSH 会话里直接跑。原生运行时不可用时返回 127 并说明原因，不会崩。
//

import Foundation

/// ObjC 可见的桥。由 `NativeOffloads/ConfigOffload.m` 里的
/// `minis-runtime` handler 调用（见 runtime_offload_register）。
@objc public final class MinisRuntimeOffloadBridge: NSObject {

    /// 运行一个运行时工具。
    /// - Parameters:
    ///   - tool: `make` / `clang` / `ldid` / `dpkg-deb` …，或 `shell` 表示运行时自带 shell。
    ///   - arguments: 传给工具的完整参数（不含 argv[0]）。
    ///   - stdin/stdout/stderr: guest 侧接过来的文件描述符。
    /// - Returns: 进程退出码（127 = 工具不存在，126 = 无法启动）。
    @objc public static func runTool(_ tool: String,
                                     arguments: [String],
                                     stdin stdinFD: Int32,
                                     stdout stdoutFD: Int32,
                                     stderr stderrFD: Int32) -> Int32 {
        let chain = NativeToolchain.shared
        let executable: String?
        if tool == "shell" {
            executable = chain.shellPath
        } else {
            executable = chain.findTool(tool)
        }
        guard let path = executable else {
            writeLine(stderrFD, "minis-runtime: 找不到运行时工具「\(tool)」。请先在 设置 → Developer Runtime 安装 Theos 运行时，或在 设置 → 运行时诊断 里重新检测。")
            return 127
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        if stdinFD >= 0 { posix_spawn_file_actions_adddup2(&actions, stdinFD, 0) }
        if stdoutFD >= 0 { posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1) }
        if stderrFD >= 0 { posix_spawn_file_actions_adddup2(&actions, stderrFD, 2) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)

        var argv: [String] = [path] + arguments
        var envPairs: [String] = []
        for (key, value) in chain.environment() {
            envPairs.append("\(key)=\(value)")
        }

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) }
        cArgs.append(nil)
        cEnv.append(nil)
        defer {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, &cArgs, &cEnv)
        guard rc == 0, pid > 0 else {
            writeLine(stderrFD, "minis-runtime: 无法启动 \(path)（posix_spawn 返回 \(rc)）。这台设备可能没有 no-sandbox / platform-application 权限。")
            return 126
        }

        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, 0)
            if waited == pid { break }
            if waited == -1 && errno == EINTR { continue }
            break
        }
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + (status & 0x7f)
    }

    private static func writeLine(_ fd: Int32, _ message: String) {
        guard fd >= 0 else { return }
        let line = message + "\n"
        _ = line.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
    }
}
