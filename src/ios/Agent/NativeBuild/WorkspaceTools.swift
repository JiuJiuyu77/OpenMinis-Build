import Foundation

/// Local, read-only project analysis. It never invokes the compiler or changes files.
enum WorkspaceAnalysisTool {
    static let name = "workspace_analyze"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: "Analyze a local iOS/Theos project on the device without running shell commands or changing files. Reports source inventory, TODO/unsafe-pattern counts, Makefile/SDK hints and build readiness.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user."),
                "path": AgentToolParam(type: .string, description: "Absolute workspace/project path. Device paths are preferred; /var/minis paths are resolved to the active workspace."),
                "include_files": AgentToolParam(type: .boolean, description: "Include a bounded list of source files (default true)."),
                "max_files": AgentToolParam(type: .integer, description: "Maximum files to list (default 120).")
            ],
            required: ["tool_title", "path"],
            propertyOrdering: ["tool_title", "path", "include_files", "max_files"]
        )
    }

    static func analyze(root: URL, includeFiles: Bool = true, maxFiles: Int = 120) -> String {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var counts: [String: Int] = [:]
        var files: [String] = []
        var todos: [String] = []
        var warnings: [String] = []
        let extensions: Set<String> = ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "x", "xm", "plist", "json"]
        let excluded = Set([".git", ".theos", "build", "DerivedData", "Pods"])
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return "Error: cannot enumerate workspace at \(rootPath)"
        }
        while let item = en.nextObject() as? URL {
            let relative = item.path.replacingOccurrences(of: rootPath + "/", with: "")
            if relative.split(separator: "/").contains(where: { excluded.contains(String($0)) }) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { en.skipDescendants() }
                continue
            }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory != true else { continue }
            let ext = item.pathExtension.lowercased()
            guard extensions.contains(ext) || item.lastPathComponent == "Makefile" || item.lastPathComponent == "control" else { continue }
            counts[ext.isEmpty ? item.lastPathComponent : ext, default: 0] += 1
            if includeFiles && files.count < max(1, min(maxFiles, 500)) { files.append(relative) }
            guard (values?.fileSize ?? 0) <= 2_000_000, let text = try? String(contentsOf: item, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let s = String(line)
                if s.range(of: "TODO|FIXME|fatalError\\(|force unwrap", options: .regularExpression) != nil && todos.count < 80 {
                    todos.append("\(relative):\(index + 1): \(s.trimmingCharacters(in: .whitespaces).prefix(180))")
                }
            }
        }
        let makefile = fm.fileExists(atPath: root.appendingPathComponent("Makefile").path)
        let control = fm.fileExists(atPath: root.appendingPathComponent("control").path)
        let sdk26 = fm.fileExists(atPath: root.appendingPathComponent("SDK26.0.sdk").path)
            || fm.fileExists(atPath: root.appendingPathComponent("iPhoneOS26.0.sdk").path)
        if !makefile { warnings.append("No Makefile found; use native_build make_mode=generate only when appropriate.") }
        if !control { warnings.append("No Debian control file found; a dylib-only target may still be valid.") }
        if !sdk26 { warnings.append("Project-local iPhoneOS26.0.sdk not found; SDK selection will use the installed Theos SDKs.") }
        var out = ["Workspace analysis", "root: \(rootPath)", "files: \(counts.values.reduce(0, +))", "types: " + counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", "), "makefile: \(makefile ? "yes" : "no")", "control: \(control ? "yes" : "no")", "sdk26_local: \(sdk26 ? "yes" : "no")"]
        if !warnings.isEmpty { out += ["", "warnings:"] + warnings.map { "- \($0)" } }
        if !todos.isEmpty { out += ["", "review_items:"] + todos.map { "- \($0)" } }
        if includeFiles { out += ["", "files:"] + files.map { "- \($0)" } }
        return out.joined(separator: "\n")
    }
}

/// Git operations are deliberately limited to read/status/diff and explicit commit.
/// The tool runs against a resolved local workspace and never changes runtime state.
enum WorkspaceGitTool {
    static let name = "workspace_git"
    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: "Run safe local Git operations for the current workspace: status, diff, log, branch, or an explicit commit. Uses the native device filesystem and does not access credentials.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user."),
                "path": AgentToolParam(type: .string, description: "Absolute workspace/project path."),
                "action": AgentToolParam(type: .string, description: "Git operation.", enumValues: ["status", "diff", "log", "branch", "commit"]),
                "message": AgentToolParam(type: .string, description: "Commit message; required only for commit."),
                "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default 30).")
            ],
            required: ["tool_title", "path", "action"],
            propertyOrdering: ["tool_title", "path", "action", "message", "timeout"]
        )
    }

    static func command(action: String, message: String?) -> String? {
        switch action {
        case "status": return "git status --short --branch"
        case "diff": return "git diff --stat && git diff --no-ext-diff"
        case "log": return "git log -8 --oneline --decorate"
        case "branch": return "git branch --show-current && git branch --list"
        case "commit":
            guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let escaped = message.replacingOccurrences(of: "'", with: "'\\''")
            return "git add -A && git commit -m '\(escaped)'"
        default: return nil
        }
    }
}

/// Build optimization levels shared by the workbench and native_build.
enum BuildOptimizationLevel: String, CaseIterable, Identifiable, Codable {
    case debug, size, speed, aggressive
    var id: String { rawValue }
    var displayName: String {
        switch self { case .debug: return AppLocalized("Debug (-O0)"); case .size: return AppLocalized("Size (-Os)"); case .speed: return AppLocalized("Speed (-O2)"); case .aggressive: return AppLocalized("Aggressive (-O3)") }
    }
    var compilerFlag: String {
        switch self { case .debug: return "-O0"; case .size: return "-Os"; case .speed: return "-O2"; case .aggressive: return "-O3" }
    }
    static func parse(_ raw: String?) -> BuildOptimizationLevel { raw.flatMap(Self.init(rawValue:)) ?? .speed }
}

/// SDK selection is capability-only: it never downloads or executes an SDK.
enum BuildSDKVersion: String, CaseIterable, Identifiable, Codable {
    case sdk164 = "16.4"
    case sdk260 = "26.0"
    var id: String { rawValue }
    var displayName: String { "iPhoneOS \(rawValue) SDK" }
    var theosSDKName: String { "iPhoneOS\(rawValue).sdk" }
    static func parse(_ raw: String?) -> BuildSDKVersion { raw.flatMap(Self.init(rawValue:)) ?? .sdk164 }
}


/// Direct workspace read/edit tools for device-side projects. Unlike file_edit,
/// these do not route device paths through the iSH rootfs. This is the path the
/// model uses when it is asked to modify the selected local workspace.
enum WorkspaceFileTool {
    static let readName = "workspace_read"
    static let editName = "workspace_edit"

    static var definitions: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: readName,
                description: "Read UTF-8 text directly from the selected local workspace on the device. Use this before workspace_edit. It never invokes a shell and never changes files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute device path of a workspace file."),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum returned characters (default 30000).")
                ], required: ["tool_title", "path"], propertyOrdering: ["tool_title", "path", "max_length"]
            ),
            AgentToolDefinition(
                name: editName,
                description: "Modify an existing file directly in the selected local workspace on the device. Call workspace_read first; replacement is exact and refuses ambiguous matches. This is the preferred model code-edit path for local projects.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute device path of a workspace file."),
                    "old_string": AgentToolParam(type: .string, description: "Exact text to replace; must match once unless replace_all is true."),
                    "new_string": AgentToolParam(type: .string, description: "Replacement text."),
                    "replace_all": AgentToolParam(type: .boolean, description: "Replace every match instead of requiring exactly one (default false).")
                ], required: ["tool_title", "path", "old_string", "new_string"], propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
            )
        ]
    }

    static func resolve(_ raw: String) -> URL? {
        guard raw.hasPrefix("/"), !raw.contains("..") else { return nil }
        if raw.hasPrefix("/var/minis"), let mapped = NativeBuildTool.mapSandboxPathToDevice(raw) {
            return URL(fileURLWithPath: mapped)
        }
        return URL(fileURLWithPath: raw)
    }

    static func read(path raw: String, maxLength: Int) -> (String, Bool) {
        guard let url = resolve(raw) else { return ("Error: invalid workspace path", false) }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ("Error: cannot read UTF-8 file at \(raw)", false)
        }
        let limit = max(1000, min(maxLength, 200_000))
        if text.count > limit { return (String(text.prefix(limit)) + "\n[TRUNCATED]", true) }
        return (text, true)
    }

    static func edit(path raw: String, oldString: String, newString: String, replaceAll: Bool) async -> (String, Bool) {
        guard let url = resolve(raw) else { return ("Error: invalid workspace path", false) }
        do {
            let outcome: FileToolIO.EditOutcome = try await FileToolIO.run("workspace_edit", writes: true, url: url) { cancellation in
                try FileToolIO.editFile(url, path: raw, oldString: oldString, newString: newString, replaceAll: replaceAll, cancellation: cancellation)
            }
            switch outcome {
            case let .edited(replacements, bytes, fuzzyNote):
                return ("✓ Edited \(raw) (\(replacements) replacement(s), \(bytes) bytes)" + (fuzzyNote.map { "\n\($0)" } ?? ""), true)
            case let .failed(message): return (message, false)
            }
        } catch { return ("Error: \(error.localizedDescription)", false) }
    }
}

extension WorkspaceGitTool {
    static func perform(args: [String: Any]) async -> (String, Bool) {
        let raw = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let action = (args["action"] as? String) ?? "status"
        guard let url = WorkspaceFileTool.resolve(raw), FileManager.default.fileExists(atPath: url.path) else { return ("Error: workspace not found at \(raw)", false) }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { return ("Error: no .git directory at \(url.path)", false) }
        guard let command = command(action: action, message: args["message"] as? String) else { return ("Error: commit requires a non-empty message", false) }
        let timeout = TimeInterval((args["timeout"] as? Int) ?? 30)
        let env = NativeToolchain.shared.environment(projectPath: url.path)
        let result = await NativeCommandRunner.run(command: command, in: url.path, environment: env, timeout: timeout)
        return (result.output.isEmpty ? "exit_code=\(result.exitCode)" : result.output, result.ok)
    }
}

