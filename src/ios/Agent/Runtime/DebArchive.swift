//
//  DebArchive.swift
//  Minis — 最小化的 Debian 包（`.deb`）读取器
//
//  为什么需要它：运行时清单里 `codex` 发布的是 `.deb`（`!<arch>` 归档），
//  而安装器原来只会解 `.tar.gz`，于是 Codex 在设置页里被标成“无法安装”。
//
//  `.deb` 的结构很简单，可以完全在 Swift 里读：
//
//      !<arch>\n
//      debian-binary   4 bytes   "2.0\n"
//      control.tar.gz  …         （可选，装完不需要）
//      data.tar.gz     …         ← 这才是要解开的文件树
//
//  三个成员的名字都以 `/` 结尾（GNU ar 约定），长度字段是十进制 ASCII，
//  每个成员按 2 字节对齐。这里只做读取与提取，不解控制脚本——运行时的
//  目的就是把 `data.tar.*` 铺到安装目录。
//

import Foundation

enum DebArchive {

    enum DebError: LocalizedError {
        case notDeb
        case truncated
        case missingDataMember
        case unsupportedDataMember(String)

        var errorDescription: String? {
            switch self {
            case .notDeb: return "Not a Debian package (missing !<arch> magic)"
            case .truncated: return "Debian package is truncated"
            case .missingDataMember: return "Debian package has no data.tar member"
            case .unsupportedDataMember(let name):
                return "Unsupported data member \(name) — this .deb needs dpkg-deb to unpack"
            }
        }
    }

    /// One `ar` member: where its payload lives inside the file.
    struct Member {
        let name: String
        let offset: Int
        let size: Int
    }

    /// Parse the member table. Cheap: reads only 60-byte headers and seeks,
    /// so a 100 MB package is not loaded into memory.
    static func members(of url: URL) throws -> [Member] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DebError.notDeb
        }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 8), magic.count == 8,
              magic == Data("!<arch>\n".utf8) else {
            throw DebError.notDeb
        }

        var result: [Member] = []
        var cursor = 8
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        while true {
            guard let header = try? handle.read(upToCount: 60), header.count == 60 else { break }
            // 名字字段（16 字节）以 '/' 结尾；长度字段（10 字节 ASCII）。
            let nameField = String(decoding: header.prefix(16), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let sizeField = String(decoding: header[48..<58], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeField), size >= 0 else { throw DebError.truncated }

            let payloadOffset = cursor + 60
            if Int64(payloadOffset) + Int64(size) > total { throw DebError.truncated }

            var name = nameField
            if name.hasSuffix("/") { name.removeLast() }
            // BSD 变体用 `#1/<len>` 表示长名，这次不处理——运行时的 deb 都是 GNU 格式。
            result.append(Member(name: name, offset: payloadOffset, size: size))

            // 每个成员按 2 字节对齐。
            cursor = payloadOffset + size + (size % 2)
            guard (try? handle.seek(toOffset: UInt64(cursor))) != nil else { break }
        }
        return result
    }

    /// Copy one member's payload out to `destination`.
    static func extract(_ member: Member, from url: URL, to destination: URL,
                        isCancelled: () -> Bool = { false }) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        try source.seek(toOffset: UInt64(member.offset))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }

        var remaining = member.size
        let chunkSize = 1 << 20
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let want = min(chunkSize, remaining)
            guard let chunk = try? source.read(upToCount: want), !chunk.isEmpty else {
                throw DebError.truncated
            }
            try sink.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    /// The member holding the file tree, if this package can be unpacked
    /// without a full dpkg. `data.tar.gz` / `data.tar.xz` handled by the caller
    /// as available; `data.tar.zst` requires dpkg-deb.
    static func dataMember(in members: [Member]) throws -> Member {
        guard let member = members.first(where: { $0.name.hasPrefix("data.tar") }) else {
            throw DebError.missingDataMember
        }
        return member
    }

    /// `.tar.gz` / `.tgz` payloads can go straight through our own extractor.
    static func isGzipPayload(_ name: String) -> Bool {
        name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
    }

    /// zstd / xz need an external tool (dpkg-deb or tar+zstd), which the
    /// installer resolves separately.
    static func isExternalPayload(_ name: String) -> Bool {
        name.hasSuffix(".tar.zst") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.bz2")
    }
}
