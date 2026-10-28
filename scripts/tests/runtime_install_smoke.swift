// Host-only executable tests for production tar parser, overlay and probe.
import Foundation
import Darwin
struct AppLogger {
    init(category: String) {}
    func info(_ text: String) {}
}
func AppLocalized(_ text: String) -> String { text }
struct RuntimeDescriptor {
    var id = "fixture"
    var version = "1"
    var handler: String? = "portable-v1"
    var install: RuntimeInstallSpec
    var installSpecOrNone: RuntimeInstallSpec { install }
}
enum NativeSpawnIdentity {
    static func configure(_ attributes: inout posix_spawnattr_t?) -> Int32 { 0 }
}

@main struct RuntimeInstallSmoke {
    static func require(_ value: Bool, _ reason: String) { if !value { fatalError(reason) } }
    static func spec(_ json: String) throws -> RuntimeInstallSpec {
        try JSONDecoder().decode(RuntimeInstallSpec.self, from: Data(json.utf8))
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let empty = try spec("{\"path_entries\":[]}")
        let overlay = RuntimeEnvironmentOverlay.build(descriptor: .init(install: empty), root: root)
        require(overlay.pathEntries.isEmpty, "explicit empty PATH was overridden")
        let legacy = RuntimeEnvironmentOverlay.build(descriptor: .init(install: try spec("{}")), root: root)
        require(legacy.pathEntries == [bin.path], "missing PATH must use safe legacy bin fallback")
        do { _ = try spec("{\"path_entries\":[\"../escape\"]}"); fatalError("unsafe install path accepted") } catch {}
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        require(RuntimePathPolicy.containedURL("escape/file", in: root) == nil, "symlink escape accepted")
        let good = root.appendingPathComponent("good")
        try RuntimeTarGzExtractor.extract(fixtures.appendingPathComponent("good.tar.gz"), to: good)
        let tool = good.appendingPathComponent("bin/tool")
        require(FileManager.default.isExecutableFile(atPath: tool.path), "tar lost executable bit")
        require(try String(contentsOf: good.appendingPathComponent("file"), encoding: .utf8) == "fixture", "tar payload mismatch")
        for name in ["traversal", "symlink-escape", "truncated"] {
            do {
                try RuntimeTarGzExtractor.extract(fixtures.appendingPathComponent(name + ".tar.gz"), to: root.appendingPathComponent(name))
                fatalError("unsafe/truncated tar accepted: " + name)
            } catch {}
        }
        let probe = RuntimeProbeRunner.run(executable: "/bin/sh", arguments: ["-c", "pwd; printf probe-ok"],
            environment: ProcessInfo.processInfo.environment, workingDirectory: good.path, timeout: 4)
        require(probe.spawnError == nil && probe.status == 0 && probe.output.contains(good.path), "probe ignored working directory")
        let timed = RuntimeProbeRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 10"],
            environment: ProcessInfo.processInfo.environment, workingDirectory: good.path, timeout: 0.1)
        require(timed.timedOut, "probe timeout did not fire")
        print("PASS: production tar extraction, modes/links, explicit empty PATH, containment, probe cwd/timeout")
    }
}
