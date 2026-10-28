//
//  ZstdDecompressor.swift
//  Minis — 用 libzstd（dlopen）解 zstd 流
//
//  为什么 dlopen 而不是静态链接：zip/tar.gz 之外的 zstd 只在“安装 .deb 运行时”
//  时用到一次。App 里没有链接 zstd，如果为这一次能力再加一份静态库，二进制会
//  白白变大。dlopen 的语义也好：设备上找不到 libzstd 就明确报错，不影响启动。
//
//  候选路径依次尝试：越狱布局 /var/jb → 系统 /usr/lib → 已安装运行时自带的副本。
//

import Foundation

enum ZstdDecompressor {

    enum ZstdError: LocalizedError {
        case libraryUnavailable
        case symbolsMissing
        case decompressionFailed(Int, String)
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .libraryUnavailable:
                return "libzstd was not found on this device, so .tar.zst packages cannot be unpacked."
            case .symbolsMissing:
                return "libzstd is present but is missing the decompression entry points."
            case .decompressionFailed(let code, let name):
                return "libzstd failed (\(name), code \(code))."
            case .emptyInput:
                return "The compressed stream is empty."
            }
        }
    }

    private typealias CreateFn = @convention(c) () -> OpaquePointer?
    private typealias FreeFn = @convention(c) (OpaquePointer?) -> Int
    private typealias InitFn = @convention(c) (OpaquePointer?) -> Int
    /// `ZSTD_decompressStream(ZSTD_DStream *, ZSTD_outBuffer *, ZSTD_inBuffer *)`
    /// 的返回类型是 `size_t`。缓冲区结构体按裸内存传，因为
    /// `@convention(c)` 无法表达带 Swift struct 的参数（不是 ObjC 可表示类型）。
    private typealias StreamFn = @convention(c) (OpaquePointer?,
                                                 UnsafeMutableRawPointer?,
                                                 UnsafeRawPointer?) -> Int
    private typealias IsErrorFn = @convention(c) (Int) -> UInt32
    private typealias ErrorNameFn = @convention(c) (Int) -> UnsafePointer<CChar>?

    private struct API {
        let create: CreateFn
        let free: FreeFn
        let initStream: InitFn
        let decompressStream: StreamFn
        let isError: IsErrorFn
        let errorName: ErrorNameFn
    }

    /// Candidate dylib locations, most specific first.
    static var libraryCandidates: [String] {
        var paths = [
            "/var/jb/usr/lib/libzstd.1.dylib",
            "/usr/lib/libzstd.1.dylib",
        ]
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
        if let installed = support?.appendingPathComponent("DeveloperRuntime/installed", isDirectory: true),
           let children = try? FileManager.default.contentsOfDirectory(at: installed,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) {
            for child in children {
                paths.append(child.appendingPathComponent("usr/lib/libzstd.1.dylib").path)
            }
        }
        paths.append("/var/mobile/Library/Application Support/CodexApp/PreparedRuntimes/TheosRuntime/usr/lib/libzstd.1.dylib")
        return paths
    }

    private static var cachedAPI: API?
    private static let apiLock = NSLock()

    private static func loadAPI() -> API? {
        apiLock.lock(); defer { apiLock.unlock() }
        if let cachedAPI { return cachedAPI }
        let resolved = resolve()
        // Only cache success: installing Theos may provide libzstd later.
        cachedAPI = resolved
        return resolved
    }

    private static func resolve() -> API? {
        for path in libraryCandidates where FileManager.default.fileExists(atPath: path) {
            guard let handle = dlopen(path, RTLD_NOW) else { continue }
            guard let create = dlsym(handle, "ZSTD_createDCtx"),
                  let free = dlsym(handle, "ZSTD_freeDCtx"),
                  let initStream = dlsym(handle, "ZSTD_initDStream"),
                  let stream = dlsym(handle, "ZSTD_decompressStream"),
                  let isError = dlsym(handle, "ZSTD_isError"),
                  let errorName = dlsym(handle, "ZSTD_getErrorName") else {
                dlclose(handle)
                continue
            }
            return API(create: unsafeBitCast(create, to: CreateFn.self),
                       free: unsafeBitCast(free, to: FreeFn.self),
                       initStream: unsafeBitCast(initStream, to: InitFn.self),
                       decompressStream: unsafeBitCast(stream, to: StreamFn.self),
                       isError: unsafeBitCast(isError, to: IsErrorFn.self),
                       errorName: unsafeBitCast(errorName, to: ErrorNameFn.self))
        }
        return nil
    }

    /// Whether a usable libzstd exists — the settings UI uses this to explain
    /// why a `.tar.zst` runtime cannot be unpacked on this device.
    static var isAvailable: Bool { loadAPI() != nil }

    // MARK: - Decompress

    /// Streaming decompress `source` into `destination` (a plain tar file).
    /// Chunked, so a 100 MB package never lands in memory at once.
    @discardableResult
    static func decompress(_ source: URL, to destination: URL,
                           isCancelled: () -> Bool = { false }) throws -> Int64 {
        guard let api = loadAPI() else { throw ZstdError.libraryUnavailable }
        guard let input = try? FileHandle(forReadingFrom: source) else { throw ZstdError.emptyInput }
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        guard let ctx = api.create() else {
            throw ZstdError.decompressionFailed(-1, "createDCtx")
        }
        defer { _ = api.free(ctx) }

        let initResult = api.initStream(ctx)
        if api.isError(initResult) != 0 {
            throw ZstdError.decompressionFailed(initResult, errorName(api, initResult))
        }

        let chunkSize = 1 << 20
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var totalWritten: Int64 = 0
        var sawFrame = false
        var lastHint = 0

        while true {
            guard let chunk = try? input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count > 0 else { return }
                // ZSTD_inBuffer { const void *src; size_t size; size_t pos; }
                // 用 24 字节裸内存构造，字段按 8 字节对齐写入。
                let inStorage = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
                defer { inStorage.deallocate() }
                inStorage.storeBytes(of: base, toByteOffset: 0, as: UnsafeRawPointer.self)
                inStorage.storeBytes(of: raw.count, toByteOffset: 8, as: Int.self)
                inStorage.storeBytes(of: 0, toByteOffset: 16, as: Int.self)

                while true {
                    let pos = inStorage.load(fromByteOffset: 16, as: Int.self)
                    if pos >= raw.count { break }

                    let produced: Int = try outBuffer.withUnsafeMutableBytes { out -> Int in
                        let outStorage = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
                        defer { outStorage.deallocate() }
                        outStorage.storeBytes(of: out.baseAddress!, toByteOffset: 0, as: UnsafeMutableRawPointer.self)
                        outStorage.storeBytes(of: out.count, toByteOffset: 8, as: Int.self)
                        outStorage.storeBytes(of: 0, toByteOffset: 16, as: Int.self)

                        let hint = api.decompressStream(ctx, outStorage, UnsafeRawPointer(inStorage))
                        if api.isError(hint) != 0 {
                            throw ZstdError.decompressionFailed(hint, errorName(api, hint))
                        }
                        lastHint = hint
                        let written = outStorage.load(fromByteOffset: 16, as: Int.self)
                        if written > 0 {
                            let piece = Data(bytes: out.baseAddress!, count: written)
                            try output.write(contentsOf: piece)
                            totalWritten += Int64(written)
                            sawFrame = true
                        }
                        return written
                    }

                    // 输入未推进且没有产出 = 这一帧到此为止（或流已结束）。
                    if produced == 0 {
                        let newPos = inStorage.load(fromByteOffset: 16, as: Int.self)
                        if newPos == pos { break }
                    }
                }
            }
        }

        guard sawFrame else { throw ZstdError.emptyInput }
        // `lastHint == 0` 表示最后一个 frame 完整结束；非 0 说明流被截断。
        if lastHint != 0 {
            logger.warning("[runtime] zstd stream ended with \(lastHint) bytes still expected — treating as truncated")
            throw ZstdError.decompressionFailed(lastHint, "truncated stream")
        }
        return totalWritten
    }

    private static let logger = AppLogger(category: "Runtime")

    private static func errorName(_ api: API, _ code: Int) -> String {
        guard let pointer = api.errorName(code) else { return "unknown" }
        return String(cString: pointer)
    }
}
