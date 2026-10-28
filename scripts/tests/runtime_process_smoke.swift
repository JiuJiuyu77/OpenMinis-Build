// Standalone macOS harness for the production iOS process runner and bridge.
// swiftc -parse-as-library NativeCommandRunner.swift RuntimeOffloadBridge.swift <this file>
import Foundation
import Darwin

struct NativeToolchain {
    static let shared = NativeToolchain()
    var shellPath: String? { "/bin/sh" }
    static func allShellCandidates() -> [String] { ["/bin/sh"] }
    func findTool(_ name: String) -> String? {
        let path = "/bin/" + name
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    func environment() -> [String: String] { ProcessInfo.processInfo.environment }
}

@main struct RuntimeProcessSmoke {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func run(_ command: String, timeout: TimeInterval = 5) async -> NativeCommandRunner.Result {
        await NativeCommandRunner.run(command: command, in: NSTemporaryDirectory(),
            environment: ProcessInfo.processInfo.environment, timeout: timeout, shellOverride: "/bin/sh")
    }
    static func bridge(_ args: [String], input: Int32, output: Int32) -> Int32 {
        var pointers = args.map { strdup($0) }
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer {
            minisRuntimeRunTool(Int32(args.count), $0.baseAddress, input, output, output)
        }
    }
    static func main() async {
        let normal = await run("printf 'runtime-ok\\n'; exit 7")
        require(normal.exitCode == 7 && normal.output == "runtime-ok\n", "exit/output mismatch: \(normal)")
        let utf8 = await run("printf '\\344'; sleep 0.05; printf '\\270\\255\\346\\226\\207\\n'; printf '\\377bad\\nok\\n'")
        require(utf8.output == "中文\n�bad\nok\n", "UTF-8 byte framing failed: \(utf8.output)")
        let signals = await run("kill -TERM $$")
        require(signals.exitCode == 143, "signal termination mismatch")
        let timed = await run("sleep 10", timeout: 0.2)
        require(timed.timedOut && timed.exitCode == 124 && timed.duration < 4, "timeout did not terminate the process group")
        let started = Date()
        async let first = run("sleep 0.7; printf first")
        async let second = run("sleep 0.7; printf second")
        let pair = await (first, second)
        require(pair.0.ok && pair.1.ok && Date().timeIntervalSince(started) < 1.8, "independent children were serialized")
        let background = await run("sleep 8 & printf parent-finished")
        require(background.ok && background.duration < 4, "inherited stdout stalled reader cleanup")
        require(background.output == "parent-finished\n", "background parent output lost")

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        require(FileManager.default.createFile(atPath: scratch.path, contents: Data()), "create capture file")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fd = open(scratch.path, O_RDWR)
        let null = open("/dev/null", O_RDONLY)
        defer { close(fd); close(null) }
        require(minisRuntimeBridgeVersion() == 1, "C ABI version changed")
        require(bridge(["sh", "-c", "printf bridge-ok; exit 9"], input: null, output: fd) == 9, "C ABI return code")
        let captured = try! Data(contentsOf: scratch)
        require(String(decoding: captured, as: UTF8.self) == "bridge-ok", "C ABI stdout forwarding")
        require(bridge(["../sh"], input: null, output: fd) == 2, "tool traversal accepted")
        require(bridge(["not-a-real-tool"], input: null, output: fd) == 127, "missing tool did not return 127")
        require(minisRuntimeRunTool(0, nil, null, fd, fd) == 2, "invalid C ABI input accepted")
        print("PASS: production process runner + C ABI smoke (output, UTF-8, status, timeout, parallelism, pipes, argv/fds)")
    }
}
