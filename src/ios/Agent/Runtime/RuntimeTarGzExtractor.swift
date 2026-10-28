import Foundation
import zlib

private let logger = AppLogger(category: "Runtime")

/// Streaming `tar.gz` extraction for developer runtime archives.
///
/// iOS has no unzip/untar API and the app links no archive library. Backups use
/// a hand-rolled ZIP reader; runtime archives are gzip-compressed POSIX tar
/// (Theos ships `TheosRuntime.tar.gz` at ~220MB, ~1GB unpacked), so this reads
/// the gzip stream once through zlib's `inflate` and parses tar headers as the
/// bytes arrive. Nothing materialises a whole member — even the 200MB SDKs —
/// and each file is written in 1MB chunks under its own autorelease pool, the
/// same jetsam discipline as `BackupBlobStore.sha256OfFile`.
enum RuntimeTarGzExtractor {

    enum ExtractError: LocalizedError {
        case notGzip
        case notTar
        case truncated
        case corrupt(String)
        case unsupportedType(UInt8, String)
        case unsafePath(String)
        case writeFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .notGzip: return "Not a gzip archive"
            case .notTar: return "Archive is not a POSIX tar"
            case .truncated: return "Archive is truncated"
            case .corrupt(let reason): return "Archive is corrupt (\(reason))"
            case .unsupportedType(let type, let name):
                return String(format: "Unsupported tar entry type 0x%02X for %@",
                              Int32(type), name)
            case .unsafePath(let path): return "Refusing unsafe entry path: \(path)"
            case .writeFailed(let path, let error):
                return "Could not write \(path): \(error.localizedDescription)"
            }
        }
    }

    struct Progress {
        var bytesWritten: Int64
        var entriesWritten: Int
    }

    /// Byte cap for one gzip member header/name field; guards a corrupt stream
    /// from asking for an unbounded buffer.
    private static let maxStringField = 1024 * 1024
    private static let progressStep = 1024 * 1024
    private static let copyBuffer = 256 * 1024

    /// Extract `archive` under `destination`.
    ///
    /// - Parameters:
    ///   - progress: called on the calling thread, throttled to ~1MB.
    ///   - isCancelled: polled before each chunk; throwing
    ///     `CancellationError()` leaves partially written files behind, so the
    ///     caller is expected to remove `destination` on failure.
    static func extract(_ archive: URL,
                        to destination: URL,
                        isCancelled: () -> Bool = { false },
                        progress: ((Progress) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let gz = try? FileHandle(forReadingFrom: archive) else {
            throw ExtractError.notGzip
        }
        defer { try? gz.close() }

        let inflater = GzipInflater()
        var parser = TarParser(destination: destination, progress: progress)

        do {
            while true {
                if isCancelled() { throw CancellationError() }

                let chunk: Data = try autoreleasepool {
                    guard let read = try gz.read(upToCount: copyBuffer), !read.isEmpty else {
                        return Data()
                    }
                    return read
                }
                if chunk.isEmpty { break }

                try inflater.inflate(chunk, isCancelled: isCancelled) { plain in
                    try autoreleasepool { try parser.consume(plain) }
                }
                // Keep reading until the file itself ends: a gzip stream may
                // hold several members, and the tar terminator is only visible
                // after the last one.
            }
        } catch let error as ExtractError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExtractError.corrupt(error.localizedDescription)
        }

        guard inflater.didReadHeader else { throw ExtractError.notGzip }
        guard inflater.didSeeMemberEnd, inflater.isAtMemberEnd else { throw ExtractError.truncated }
        try parser.finish()
        logger.info("Extracted \(parser.entriesWritten) entries, \(parser.bytesWritten) bytes to \(destination.lastPathComponent)")
    }

    /// Extract an UNCOMPRESSED tar file. Used after a `.deb`'s `data.tar.zst`
    /// has been decompressed to a plain tar, and for `data.tar` members that
    /// ship uncompressed.
    static func extractPlainTar(_ archive: URL,
                                to destination: URL,
                                isCancelled: () -> Bool = { false },
                                progress: ((Progress) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let handle = try? FileHandle(forReadingFrom: archive) else {
            throw ExtractError.notTar
        }
        defer { try? handle.close() }

        var parser = TarParser(destination: destination, progress: progress)
        do {
            while true {
                if isCancelled() { throw CancellationError() }
                let chunk: Data = try autoreleasepool {
                    guard let read = try handle.read(upToCount: copyBuffer), !read.isEmpty else {
                        return Data()
                    }
                    return read
                }
                if chunk.isEmpty { break }
                try autoreleasepool { try parser.consume(chunk) }
            }
        } catch let error as ExtractError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExtractError.corrupt(error.localizedDescription)
        }

        try parser.finish()
        logger.info("Extracted \(parser.entriesWritten) entries from plain tar to \(destination.lastPathComponent)")
    }

    // MARK: - Gzip

    /// Incremental gzip reader over zlib's `inflate` (window bits 16+15 = gzip).
    private final class GzipInflater {
        private var stream = z_stream()
        private var initialised = false
        private(set) var didSeeMemberEnd = false
        private(set) var didReadHeader = false
        private(set) var totalIn: Int64 = 0
        private(set) var totalOut: Int64 = 0

        deinit { if initialised { inflateEnd(&stream) } }

        private func startIfNeeded() throws {
            guard !initialised else { return }
            // 31 = 16 (gzip wrapper) + 15 (max window). `zlibVersion()` avoids
            // depending on how the `ZLIB_VERSION` macro is imported.
            let status = inflateInit2_(&stream, 31, zlibVersion(),
                                       Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else {
                throw ExtractError.corrupt("inflateInit2 returned \(status)")
            }
            initialised = true
        }

        func inflate(_ input: Data, isCancelled: () -> Bool,
                     consume: (Data) throws -> Void) throws {
            try startIfNeeded()
            // A gzip file may contain concatenated members, and a member
            // boundary can fall inside one read chunk. Consume the remainder
            // of the chunk after restarting instead of dropping it.
            try input.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else {
                    return
                }
                totalIn += Int64(raw.count)

                var buffer = [UInt8](repeating: 0, count: copyBuffer)
                var offset = 0
                while offset < raw.count {
                    if isCancelled() { throw CancellationError() }
                    if reachedStreamEnd { try restartForNextMember() }
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base + offset)
                    stream.avail_in = uInt(raw.count - offset)

                    while true {
                        if isCancelled() { throw CancellationError() }
                        // Failures return zlib's own negative code
                        // (Z_BUF_ERROR is -5), so they can never be confused
                        // with a byte count. A truncated member returns
                        // Z_BUF_ERROR forever when fed the same exhausted
                        // input.
                        let produced: Int = buffer.withUnsafeMutableBufferPointer { out -> Int in
                            stream.next_out = out.baseAddress
                            stream.avail_out = uInt(out.count)
                            let status = zlib.inflate(&stream, Z_NO_FLUSH)
                            if status == Z_STREAM_END {
                                reachedStreamEnd = true
                                didSeeMemberEnd = true
                            } else if status == Z_BUF_ERROR && stream.avail_in == 0 {
                                return 0
                            } else if status != Z_OK {
                                return Int(status)
                            }
                            if !didReadHeader && (stream.total_out > 0 || status == Z_STREAM_END) {
                                didReadHeader = true
                            }
                            return out.count - Int(stream.avail_out)
                        }
                        if produced < 0 {
                            throw ExtractError.corrupt("inflate returned \(produced)")
                        }
                        if produced > 0 {
                            try consume(Data(buffer[0..<produced]))
                            totalOut += Int64(produced)
                        }
                        // Only stop at end-of-member, when the input is truly
                        // drained, or when inflate made no progress. A full
                        // output buffer means `avail_out == 0` while input may
                        // remain, so that case must loop again; calling
                        // inflate with `avail_in == 0` returns Z_BUF_ERROR.
                        if reachedStreamEnd { break }
                        if stream.avail_in == 0 && stream.avail_out > 0 { break }
                        if produced == 0 { break }
                    }

                    let consumed = (raw.count - offset) - Int(stream.avail_in)
                    offset += consumed
                    if consumed == 0 {
                        // No progress and no end-of-member: a corrupt stream
                        // would otherwise spin here forever.
                        if !reachedStreamEnd {
                            throw ExtractError.corrupt("inflate made no progress")
                        }
                        break
                    }
                }
            }
        }

        private var reachedStreamEnd = false
        var isAtMemberEnd: Bool { reachedStreamEnd }

        private func restartForNextMember() throws {
            inflateEnd(&stream)
            stream = z_stream()
            initialised = false
            reachedStreamEnd = false
            try startIfNeeded()
        }
    }

    // MARK: - Tar

    private struct TarParser {
        let destination: URL
        let progress: ((Progress) -> Void)?

        private var buffer = Data()
        private var current: Entry?
        private var sink: FileHandle?
        private var remaining: Int64 = 0
        private var padRemaining: Int64 = 0
        private var longName: String?
        private var longLink: String?
        private var metadataIsLink = false
        private var metaBuffer: Data?
        private(set) var bytesWritten: Int64 = 0
        private(set) var entriesWritten = 0
        private var lastProgressBytes: Int64 = 0
        private var sawTerminator = false

        private struct Entry {
            var path: String
            var size: Int64
            var mode: Int64?
            var isDirectory: Bool
            var isSymlink: Bool
            var linkTarget: String?
            var isHardlink: Bool
            var isMetadata: Bool
        }

        init(destination: URL, progress: ((Progress) -> Void)?) {
            self.destination = destination
            self.progress = progress
        }

        mutating func consume(_ data: Data) throws {
            buffer.append(data)
            while true {
                if remaining > 0 {
                    let take = Int(min(Int64(buffer.count), remaining))
                    guard take > 0 else { return }
                    let piece = buffer.prefix(take)
                    buffer.removeSubrange(0..<take)
                    if current?.isMetadata == true {
                        metaBuffer?.append(piece)
                        bytesWritten += Int64(take)
                    } else {
                        try write(piece)
                    }
                    remaining -= Int64(take)
                    if remaining == 0 { try finishEntry() }
                    continue
                }
                if padRemaining > 0 {
                    let take = Int(min(Int64(buffer.count), padRemaining))
                    guard take > 0 else { return }
                    buffer.removeSubrange(0..<take)
                    padRemaining -= Int64(take)
                    continue
                }
                guard buffer.count >= 512 else { return }
                let header = buffer.prefix(512)
                buffer.removeSubrange(0..<512)
                try beginEntry(header: Data(header))
            }
        }

        mutating func finish() throws {
            guard current == nil, remaining == 0, padRemaining == 0, buffer.allSatisfy({ $0 == 0 }),
                  longName == nil, longLink == nil, metaBuffer == nil else {
                throw ExtractError.truncated
            }
            guard sawTerminator else { throw ExtractError.truncated }
            try? sink?.close()
            sink = nil
        }

        private mutating func write(_ data: Data) throws {
            if metaBuffer != nil {
                metaBuffer?.append(data)
                bytesWritten += Int64(data.count)
                return
            }
            guard let handle = sink else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw ExtractError.writeFailed("current entry", error)
            }
            bytesWritten += Int64(data.count)
            if let progress, bytesWritten - lastProgressBytes >= progressStep {
                lastProgressBytes = bytesWritten
                progress(Progress(bytesWritten: bytesWritten, entriesWritten: entriesWritten))
            }
        }

        private mutating func beginEntry(header: Data) throws {
            if header.allSatisfy({ $0 == 0 }) {
                // Two zero blocks end a tar archive. Stopping at the first one
                // still accepts every well-formed archive; a stream that ends
                // without one is caught by `finish()`.
                sawTerminator = true
                return
            }
            guard header.count >= 512 else { throw ExtractError.truncated }
            guard !sawTerminator else { throw ExtractError.corrupt("entry after tar terminator") }
            let checksum = try octal(header, 148, 8)
            let actual = header.enumerated().reduce(Int64(0)) { sum, item in
                sum + Int64((148..<156).contains(item.offset) ? 32 : item.element)
            }
            guard checksum == actual else { throw ExtractError.corrupt("tar header checksum mismatch") }

            let type = header[156]
            let size = try octal(header, 124, 12)
            let mode = try octal(header, 100, 8)
            let name = try stringField(header, 0, 100)
            let prefix = try stringField(header, 345, 155)
            var linkTarget = try stringField(header, 157, 100)

            if type == UInt8(ascii: "L") || type == UInt8(ascii: "K") {
                guard size <= Int64(maxStringField) else {
                    throw ExtractError.corrupt("oversized GNU long-name record")
                }
                metadataIsLink = type == UInt8(ascii: "K")
                metaBuffer = Data()
                metaBuffer?.reserveCapacity(Int(size))
                remaining = size
                current = Entry(path: "", size: size, mode: nil, isDirectory: false,
                                isSymlink: false, linkTarget: nil, isHardlink: false,
                                isMetadata: true)
                padRemaining = size % 512 == 0 ? 0 : 512 - (size % 512)
                // A zero-length long-name record has no payload, so nothing
                // would call finishEntry(); finish it here or the next header
                // is parsed while `current` is still set.
                if size == 0 { try finishEntry() }
                return
            }

            var full = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if let longName { full = longName }
            if let longLink { linkTarget = longLink }
            longName = nil
            longLink = nil

            guard !full.hasPrefix("/") else { throw ExtractError.unsafePath(full) }
            if full.hasPrefix("./") { full.removeFirst(2) }
            while full.count > 1, full.hasSuffix("/") { full.removeLast() }

            // tar -C tree . emits ./ as a harmless root directory entry.
            if full.isEmpty && type == UInt8(ascii: "5") {
                full = "."
            }
            let resolved = try safeDestination(for: full)
            let isDirectory = type == UInt8(ascii: "5") || full.hasSuffix("/")
            let isSymlink = type == UInt8(ascii: "2")
            let isHardlink = type == UInt8(ascii: "1")
            let isRegular = type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7")

            let fm = FileManager.default
            guard !(isDirectory || isSymlink || isHardlink) || size == 0 else {
                throw ExtractError.corrupt("non-file tar entry has a payload")
            }
            guard isDirectory || resolved.standardizedFileURL != destination.standardizedFileURL else {
                throw ExtractError.unsafePath(full)
            }

            if isDirectory {
                try fm.createDirectory(at: resolved, withIntermediateDirectories: true)
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode & 0o7777)],
                                      ofItemAtPath: resolved.path)
                entriesWritten += 1
                padRemaining = size % 512 == 0 ? 0 : 512 - (size % 512)
                return
            }

            if isSymlink {
                let parent = resolved.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                if !linkTarget.isEmpty {
                    if isContainedLinkTarget(linkTarget, at: parent) {
                        try? fm.removeItem(at: resolved)
                        try fm.createSymbolicLink(atPath: resolved.path,
                                                  withDestinationPath: linkTarget)
                    } else {
                        throw ExtractError.unsafePath("\(full) -> \(linkTarget)")
                    }
                }
                entriesWritten += 1
                padRemaining = size % 512 == 0 ? 0 : 512 - (size % 512)
                return
            }

            if isHardlink {
                let parent = resolved.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let target = try safeDestination(for: linkTarget)
                guard target != resolved else { throw ExtractError.unsafePath(full) }
                try? fm.removeItem(at: resolved)
                try fm.linkItem(at: target, to: resolved)
                entriesWritten += 1
                padRemaining = size % 512 == 0 ? 0 : 512 - (size % 512)
                return
            }

            guard isRegular else {
                throw ExtractError.unsupportedType(type, full)
            }

            try fm.createDirectory(at: resolved.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // Never truncate through a symlink or a previous hardlink inode.
            // A duplicate regular entry replaces that directory entry only.
            if (try? fm.attributesOfItem(atPath: resolved.path)) != nil {
                try fm.removeItem(at: resolved)
            }
            guard fm.createFile(atPath: resolved.path, contents: nil) else {
                throw ExtractError.writeFailed(full, CocoaError(.fileWriteUnknown))
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: resolved)
            } catch {
                throw ExtractError.writeFailed(full, error)
            }
            sink = handle
            current = Entry(path: full, size: size, mode: mode, isDirectory: false,
                            isSymlink: false, linkTarget: nil, isHardlink: false,
                            isMetadata: false)
            remaining = size
            padRemaining = size % 512 == 0 ? 0 : 512 - (size % 512)
            if size == 0 { try finishEntry() }
        }

        private mutating func finishEntry() throws {
            try? sink?.close()
            sink = nil
            if let meta = metaBuffer {
                let value = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
                if metadataIsLink { longLink = value } else { longName = value }
                metaBuffer = nil
                current = nil
                return
            }
            if let entry = current, !entry.isMetadata {
                let url = try safeDestination(for: entry.path)
                if let mode = entry.mode {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: mode & 0o7777)],
                        ofItemAtPath: url.path)
                }
                entriesWritten += 1
            }
            current = nil
        }

        /// Reject absolute paths and `..` escapes before anything is written.
        private func safeDestination(for path: String) throws -> URL {
            guard let candidate = RuntimePathPolicy.containedURL(path, in: destination) else {
                throw ExtractError.unsafePath(path)
            }
            return candidate
        }

        /// Symlink targets may point anywhere unless checked, and a following
        /// entry written through such a link escapes `destination`. Keep only
        /// targets whose normalised form stays under the extraction root.
        private func isContainedLinkTarget(_ target: String, at parent: URL) -> Bool {
            guard !target.hasPrefix("/"), !target.contains("\0") else { return false }
            guard let candidate = RuntimePathPolicy.canonicalURL(parent.appendingPathComponent(target))?.path,
                  let root = RuntimePathPolicy.canonicalURL(destination)?.path else { return false }
            return candidate == root || candidate.hasPrefix(root + "/")
        }

        private func octal(_ header: Data, _ offset: Int, _ length: Int) throws -> Int64 {
            let slice = header[offset..<(offset + length)]
            var value: Int64 = 0
            var sawDigit = false
            for (index, byte) in slice.enumerated() {
                if index == 0 && (byte & 0x80) != 0 {
                    throw ExtractError.corrupt("base-256 tar field")
                }
                if byte == 0 || byte == UInt8(ascii: " ") {
                    if sawDigit { break }
                    continue
                }
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else {
                    throw ExtractError.corrupt("invalid octal tar field")
                }
                sawDigit = true
                value = value &* 8 &+ Int64(byte - UInt8(ascii: "0"))
            }
            return value
        }

        private func stringField(_ header: Data, _ offset: Int, _ length: Int) throws -> String {
            let slice = header[offset..<(offset + length)].prefix { $0 != 0 }
            return String(decoding: slice, as: UTF8.self)
        }
    }
}
