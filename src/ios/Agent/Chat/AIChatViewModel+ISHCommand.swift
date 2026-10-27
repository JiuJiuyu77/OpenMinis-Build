import Foundation

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Command Execution (ISHShellExecutor)

extension AIChatViewModel {

    // MARK: - Command Execution (ISHShellExecutor)

    /// Result of command execution containing output text and exit code.
    struct CommandResult {
        let output: String
        let exitCode: Int
    }

    /// Execute a command via ISHExecutionCoordinator (serialized, mount-safe).
    /// Returns clean stdout+stderr output without any TTY artifacts, plus the exit code.
    func executeCommand(_ command: String, timeout: TimeInterval? = nil, lineCallback: @escaping (String) -> Void) async throws -> CommandResult {
        let effectiveTimeout = timeout ?? defaultCommandTimeout
        logger.info("Executing command via coordinator (timeout: \(Int(effectiveTimeout))s): \(command)")

        // [T-tool-executor-preference] Honour Settings → 执行器.
        //
        //   sandbox  → never leave iSH (upstream behaviour)
        //   native   → always use the on-device toolchain, fail loudly
        //   auto     → stay in iSH unless the user explicitly opted into the
        //              custom runtime ("Prefer custom runtime")
        //
        // `auto` deliberately does NOT go native just because a toolchain is
        // lying around: every existing MT-Agent install already ships one, so
        // that would silently move every shell command off iSH — a behaviour
        // change (and a spawn risk under an App Store sandbox) nobody asked
        // for. Native is opt-in only.
        //
        // iSH paths (`/var/minis/...`) stay inside the sandbox regardless, since
        // the native runner sees real device paths and would silently 404.
        let decision = await MainActor.run {
            ToolExecutorPreference.shared.executionDecision
        }
        let executor = decision.executor
        if executor != .sandbox {
            // 简化后：auto 也允许尝试原生；真正的闸门是下面的真实探针。
            let wantsNative = (executor == .native || executor == .auto)
            let nativeReady = await MainActor.run { NativeToolchain.shared.isAvailable }
            if wantsNative && !nativeReady {
                if executor == .native {
                    return CommandResult(
                        output: "Error: 原生执行器已选中，但没有找到可用的 Theos 运行时。请到 设置 → Developer Runtime 安装，或把执行器切成「自动 / iSH 沙箱」。",
                        exitCode: 127)
                }
                // auto：没有工具链就安静地走 iSH，不打扰用户。
            }
            // [T-executor-auto-fix] 以前这里只看 nativeReady：只要设备上探测到
            // 工具链，auto 模式也会把命令切到原生执行，与上面「auto 默认留在 iSH、
            // 只有显式勾选自定义 Runtime 才切」的约定相反。沙箱构建里这正是
            // libiosexec / 134 的来源。改成必须同时满足 wantsNative。
            if wantsNative && nativeReady && !command.contains("/var/minis/") {
                // [T-runtime-health] 「文件在」不等于「能跑」。沙箱里运行时自带的
                // zsh 会死在 dyld（@rpath/libiosexec.1.dylib 被 mmap 拦截），
                // 子进程 abort → 134；posix_spawn 被拒 → -1。以前只有 -1 才回退，
                // 于是 134 会把每条命令都变成一次失败的编译。
                //
                // 现在先用真实探针确认运行时可用：不可用且用户没把执行器钉死在
                // native 时，直接走 iSH，不浪费一次 abort。
                let health = await NativeRuntimeHealthMonitor.shared.refresh()
                if !health.ok {
                    if executor == .native {
                        return CommandResult(
                            output: "Error: 原生执行器已选中，但运行时无法启动：\(health.summary)\n修复：设置 → 运行时诊断 → 一键修复，或把执行器切回「自动 / 沙箱 (iSH)」。",
                            exitCode: 127)
                    }
                    logger.warning("[T-runtime-health] native runtime unusable (\(health.failure.rawValue)); using iSH")
                    lineCallback("⚠️ 原生运行时无法启动（\(health.summary)），已自动改用 iSH 沙箱。可在 设置 → 运行时诊断 点「一键修复」。")
                } else {
                    // [T-native-spawn-fallback] 探针通过后仍可能被运行期问题打死
                    // （签名失效、dylib 半路缺失）。除非用户显式钉了 .native，
                    // 否则降级到 iSH，而不是让整轮对话失败。
                    let nativeResult = try await runNatively(command: command,
                                                             timeout: effectiveTimeout,
                                                             lineCallback: lineCallback)
                    if !Self.nativeFailedToStart(nativeResult) || executor == .native {
                        return nativeResult
                    }
                    logger.warning("[T-native-spawn-fallback] native execution failed at startup; falling back to iSH")
                    lineCallback("⚠️ 原生执行器无法启动进程，已自动回退到 iSH 沙箱。原因见：设置 → 运行时诊断。")
                }
            }
        }

        // [T-p2-shared-workspace] A helper's shell runs in its parent's bucket.
        guard let sid = fsSessionId else {
            return CommandResult(output: "Error: no session", exitCode: -1)
        }

        // [T-bash-on-demand] Detect busybox-ash-incompatible bash syntax and, if
        // found, transparently install + switch to bash. Install time is NOT
        // charged against `effectiveTimeout` (it has its own budget inside
        // OnDemandBash). Only the shell_execute path reaches here; the
        // interactive terminal uses a different path and is untouched.
        let bashism = BashismDetector.detect(command)
        var bashReminder: String? = nil
        if bashism.needsBash {
            let outcome = await OnDemandBash.shared.ensureBash(executor: ishExecutor(sessionId: sid))
            switch outcome {
            case .available:
                if bashism.mustSwitchInterpreter {
                    // §3.2 M3: run the script via bash by self-writing it in the
                    // guest (base64, single line, no host→fakefs write, self-cleaning).
                    return try await runViaBash(command, sessionId: sid, timeout: effectiveTimeout,
                                                lineCallback: lineCallback)
                }
                // T1 only (script already invokes bash itself) — run as-is under sh.
            case .unavailable(let reason):
                // Fall back to sh; attach a reminder if the command then fails,
                // or immediately for silent-error (S) hits whose failure mode is
                // "looks fine, wrong result" (design §4.2 default-on exception).
                bashReminder = BashismReminder.build(hits: bashism.hits, installFailure: reason)
            }
        }
        return try await runWithReminder(command, sessionId: sid, timeout: effectiveTimeout,
                                         reminder: bashReminder, silentClass: bashism.hasSilent,
                                         lineCallback: lineCallback)
    }

    /// 原生路径「根本没起来」的判定：spawn 失败（-1）之外，还要覆盖 dyld
    /// 在子进程里 abort（134）、找不到动态库（libiosexec / Library not loaded）
    /// 以及 shell 不存在（126/127）这几种「换了环境就一定能跑」的失败。
    static func nativeFailedToStart(_ result: CommandResult) -> Bool {
        let lower = result.output.lowercased()
        if result.exitCode == -1 && lower.contains("could not start a process") { return true }
        if lower.contains("libiosexec") || lower.contains("library not loaded")
            || lower.contains("symbol not found") { return true }
        if result.exitCode == 134 && lower.contains("dyld") { return true }
        if (result.exitCode == 126 || result.exitCode == 127) && lower.contains("could not start") { return true }
        return false
    }

    /// Executor adapter handing OnDemandBash a way to run guest commands.
    private func ishExecutor(sessionId sid: String) -> OnDemandBash.Executor {
        OnDemandBash.Executor(run: { command, timeout in
            let r = try? await ISHExecutionCoordinator.shared.execute(
                sessionId: sid, command: command, timeout: timeout,
                lineCallback: { _ in }, pidCallback: { _ in })
            return r?.exitCode ?? -1
        })
    }

    /// Sentinel exit code the bash wrapper returns when bash is missing at run
    /// time (distinguishes "bash gone" from a script that legitimately exits
    /// 127). 119 is otherwise unused by our commands.
    private static let bashMissingSentinel = 119

    /// Run `script` under bash by self-writing it in the guest (M3): base64 →
    /// decode to a per-pid temp file → `bash file` → capture rc → delete. No
    /// host→fakefs write, no heredoc, self-cleaning on the same command line.
    /// The wrapper guards on `command -v bash` first so a bash that vanished
    /// between our cache check and now (user `apk del bash`) is detected
    /// precisely (M5) and self-healed inline rather than failing the command.
    private func runViaBash(_ script: String, sessionId sid: String,
                            timeout: TimeInterval,
                            lineCallback: @escaping (String) -> Void,
                            allowReinstall: Bool = true) async throws -> CommandResult {
        // [T-heredoc-trailing-newline] Same heredoc-terminator rule applies to
        // the decoded script bash runs: a heredoc that ends the file with no
        // trailing newline fails with "unexpected end of file". Guarantee one.
        let normalized = script.hasSuffix("\n") ? script : script + "\n"
        let b64 = Data(normalized.utf8).base64EncodedString()
        let f = "/tmp/.minis-exec-$$.sh"
        let wrapped = "command -v bash >/dev/null 2>&1 || exit \(Self.bashMissingSentinel); "
            + "printf %s '\(b64)' | base64 -d > \(f) && bash \(f); rc=$?; rm -f \(f); exit $rc"
        let result = try await runRaw(wrapped, sessionId: sid, timeout: timeout, lineCallback: lineCallback)

        // M5 self-heal: bash disappeared after we cached it available. Re-probe
        // and, once only, try to reinstall + rerun under bash inline so THIS
        // command still succeeds instead of the next one.
        // The coordinator can surface either the raw exit code (119) or the
        // wait(2)-encoded status (119 << 8 = 30464), so accept both.
        if result.exitCode == Self.bashMissingSentinel
            || result.exitCode == (Self.bashMissingSentinel << 8) {
            await OnDemandBash.shared.markDisappeared()
            if allowReinstall {
                let outcome = await OnDemandBash.shared.ensureBash(executor: ishExecutor(sessionId: sid))
                if case .available = outcome {
                    return try await runViaBash(script, sessionId: sid, timeout: timeout,
                                                lineCallback: lineCallback, allowReinstall: false)
                }
            }
            // Reinstall unavailable → degrade to sh so the script at least runs.
            return try await runRaw(script, sessionId: sid, timeout: timeout, lineCallback: lineCallback)
        }
        return result
    }

    /// Run `command` and, when a bash reminder applies, append it to the output
    /// per the §4.2 trigger rules (non-zero exit, OR any silent-class hit).
    private func runWithReminder(_ command: String, sessionId sid: String,
                                 timeout: TimeInterval, reminder: String?, silentClass: Bool,
                                 lineCallback: @escaping (String) -> Void) async throws -> CommandResult {
        let result = try await runRaw(command, sessionId: sid, timeout: timeout, lineCallback: lineCallback)
        guard let reminder else { return result }
        let shouldAppend = result.exitCode != 0 || silentClass
        guard shouldAppend else { return result }
        return CommandResult(output: result.output + "\n\n" + reminder, exitCode: result.exitCode)
    }

    /// The original coordinator call + output sanitation/truncation, factored
    /// out so the bash/sh/reminder wrappers share one implementation.
    private func runRaw(_ command: String, sessionId sid: String, timeout: TimeInterval,
                        lineCallback: @escaping (String) -> Void) async throws -> CommandResult {
        let effectiveTimeout = timeout

        let cmdIdx = await ShellCommandRingBuffer.shared.didStart(command: command, sessionId: sid)

        // [T-ios-shellring-counter-leak] Balance didStart on EVERY exit path.
        // The old code called didExit only on the normal-return path below, so a
        // throw (CancellationError / kernelNotBooted) or a cancelled enclosing
        // task leaked `_runningCount` permanently — leaving the entry rendered as
        // "RUNNING" forever in crash reports and making `hasRunningCommand` a
        // one-way latch that pinned keep-alive on for the rest of the process.
        //
        // Deliberately do-catch rather than `defer { Task { … } }`: a detached
        // Task spawned from a defer during CANCELLATION is exactly the case that
        // may never be scheduled, which is the main path we need to cover. An
        // `await` on the error path is structured and always runs. `exitCode`
        // stays nil so the entry records an abort, not a fake exit status.
        let result: ISHCommandResult
        do {
            result = try await ISHExecutionCoordinator.shared.execute(
                sessionId: sid,
                command: command,
                timeout: effectiveTimeout,
                // [T-shell-stop-owner] Filed under the shared workspace (`sid`)
                // but owned by THIS session, so its Stop kills only its own.
                ownerId: sessionId,
                // ISHShellExecutor dispatches every line on the main queue
                // already (ISHShellExecutor.m:780/812), so we're guaranteed to
                // run on the main thread here. Calling the MainActor-isolated
                // closure synchronously via `assumeIsolated` avoids spawning a
                // fresh `Task { @MainActor in ... }` per line — that wrapper
                // used to pile up behind high-volume output (one MainActor job
                // per line) and starve other MainActor work such as
                // BrowserUseOffloadBridge's semaphore signal, causing
                // execute_js/navigate to hang inside a Python subprocess.
                lineCallback: { line in
                    // 主线程直接调用（ISH 路径本来就在主队列），否则投递到主队列。
                    // 之前用 MainActor.assumeIsolated 同步调用，一旦某个路径在后台
                    // 队列上回调（原生执行器就是这样），就会触发 SIGTRAP 崩溃。
                    if Thread.isMainThread {
                        lineCallback(line)
                    } else {
                        DispatchQueue.main.async { lineCallback(line) }
                    }
                },
                pidCallback: { [weak self] pid in
                    // Unlike lineCallback, pidCallback is invoked from the
                    // coordinator actor context (not the main queue), so we
                    // can't MainActor.assumeIsolated here. It only fires 1-2
                    // times per command so a Task hop is fine.
                    Task { @MainActor in
                        self?.runningCommandPid = pid
                        self?.commandStartTime = pid > 0 ? Date() : nil
                    }
                }
            )
        } catch {
            await ShellCommandRingBuffer.shared.didAbort(index: cmdIdx)
            throw error
        }

        await ShellCommandRingBuffer.shared.didExit(index: cmdIdx, exitCode: result.exitCode)

        // Fold carriage-return sequences: simulate terminal line-overwrite behaviour.
        // Tools like yt-dlp emit "\r[download] X%" to overwrite the current line; without a TTY
        // every update is captured verbatim, ballooning the output with hundreds of redundant lines.
        // We replay each \r as a real terminal would: later text on the same line overwrites earlier text,
        // so only the final state of each line is kept — matching what you would actually see on screen.
        var output = Self.sanitizeTerminalOutput(result.output)

        // Apply truncation — keep head + tail so the model sees both the beginning and end
        if output.count > Self.kMaxToolResultChars {
            let totalChars = output.count
            let totalLines = output.components(separatedBy: "\n").count
            let halfLen = Self.kMaxToolResultChars / 2
            let head = String(output.prefix(halfLen))
            let tail = String(output.suffix(halfLen))
            output = head
                + "\n\n...\n\n"
                + tail
                + "\n\n[OUTPUT TRUNCATED] Showing first & last \(halfLen) of \(totalChars) chars (\(totalLines) lines total)."
                + "\nUse file_read tool to read specific sections."
        }

        return CommandResult(output: output, exitCode: result.exitCode)
    }

    /// Sanitize raw shell output so it matches what a user would actually see on a terminal.
    ///
    /// Two passes are applied in order:
    ///
    /// **Pass 1 — carriage-return folding**
    /// A real TTY processes `\r` by moving the cursor to column 0, causing subsequent
    /// characters to overwrite what was already on that line.  Pipe-captured output has
    /// no TTY, so every `\r`-update is stored verbatim.  Tools like yt-dlp, curl, wget,
    /// and rsync can emit hundreds of progress lines that are pure noise for the model.
    /// We replay the same cursor logic: within each newline-delimited chunk, split on `\r`
    /// and keep only the last non-empty segment — the text a terminal would finally display.
    ///
    /// **Pass 2 — ANSI / VT escape sequence stripping**
    /// After CR-folding the remaining text may still contain ANSI SGR colour/style codes
    /// (e.g. `\033[1;32m`, `\033[0m`), cursor-movement sequences (`\033[A`, `\033[2K`,
    /// `\033[G`), and other CSI/OSC/ST control sequences.  None of these are meaningful
    /// as plain text; stripping them produces clean output the model can reason about.
    static func sanitizeTerminalOutput(_ raw: String) -> String {
        // ── Pass 1: carriage-return folding ──────────────────────────────────────
        let crFolded: String
        if !raw.contains("\r") {
            crFolded = raw
        } else {
            var lines: [String] = []
            for chunk in raw.components(separatedBy: "\n") {
                if !chunk.contains("\r") {
                    lines.append(chunk)
                } else {
                    // Split on \r; the last non-empty segment is what the terminal shows.
                    let segments = chunk.components(separatedBy: "\r")
                    let final = segments.last(where: { !$0.isEmpty }) ?? segments.last ?? ""
                    lines.append(final)
                }
            }
            // Collapse consecutive blank lines left by folding.
            var collapsed: [String] = []
            var blankRun = 0
            for line in lines {
                if line.isEmpty {
                    blankRun += 1
                    if blankRun <= 1 { collapsed.append(line) }
                } else {
                    blankRun = 0
                    collapsed.append(line)
                }
            }
            crFolded = collapsed.joined(separator: "\n")
        }

        // ── Pass 2: ANSI / VT escape sequence stripping ──────────────────────────
        // Covers:
        //   CSI sequences  \033[ … <final byte 0x40-0x7E>  (colours, cursor movement, erase)
        //   OSC sequences  \033] … \007  or  \033] … \033\\  (window title, hyperlinks)
        //   Single-char Fe  \033[A-Z@\[\\\]^_]  (e.g. \033M reverse index)
        //   Literal ESC     \033  (bare, not followed by anything matched above)
        guard crFolded.contains("\u{1B}") else { return crFolded }

        // Single NSRegularExpression is cheap to apply; pattern is anchored to ESC.
        let pattern = "\u{1B}(?:\\[[0-9;]*[A-Za-z@`]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_]|\u{1B})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return crFolded }
        let range = NSRange(crFolded.startIndex..., in: crFolded)
        return regex.stringByReplacingMatches(in: crFolded, range: range, withTemplate: "")
    }


    // MARK: - Native execution path

    /// 走 `NativeCommandRunner`（真实 iOS 进程，不经过 iSH）。
    /// 与沙箱路径保持同样的返回语义：输出文本 + 退出码。
    private func runNatively(command: String,
                             timeout: TimeInterval,
                             lineCallback: @escaping (String) -> Void) async throws -> CommandResult {
        let env = await MainActor.run { NativeToolchain.shared.environment() }
        let result = await NativeCommandRunner.run(
            command: command,
            in: nil,
            environment: env,
            timeout: timeout,
            onLine: { line in
                // 原生路径的 onLine 在后台 reader 队列上回调（NativeCommandRunner 里
                // DispatchQueue "app.minis.native-build.reader"），MainActor.assumeIsolated
                // 会在这里直接 SIGTRAP（EXC_BREAKPOINT）。主线程直接调，否则投递到主队列。
                if Thread.isMainThread {
                    lineCallback(line)
                } else {
                    DispatchQueue.main.async { lineCallback(line) }
                }
            })
        if result.timedOut {
            return CommandResult(output: result.output + "\n\nError: command timed out after \(Int(timeout))s.",
                                 exitCode: -1)
        }
        return CommandResult(output: result.output, exitCode: Int(result.exitCode))
    }
}
