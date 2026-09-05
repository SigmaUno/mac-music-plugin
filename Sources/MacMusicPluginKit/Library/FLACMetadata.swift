import Foundation

/// A minimal FLAC metadata reader: `AVAsset.commonMetadata` plays FLAC but
/// surfaces none of its Vorbis-comment tags or embedded `PICTURE` block on
/// macOS, so `AVMetadataReader` falls back to this for `.flac` files.
///
/// Parses only the two blocks we need — `VORBIS_COMMENT` (type 4) and `PICTURE`
/// (type 6) — straight out of the file header, and only scans a bounded prefix
/// (art lives before the audio, like the C backend's `COVER_PREFIX_BYTES`).
enum FLACMetadata {
    /// Bytes to read from the front of the file. FLAC metadata (including a
    /// front-cover PICTURE) precedes the audio frames; 8 MB clears it with room
    /// to spare while keeping a remote/large file cheap to probe.
    static let prefixBytes = 8 * 1024 * 1024

    static func read(_ url: URL) -> ExtractedMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: prefixBytes), data.count >= 8 else { return nil }
        return parse(data)
    }

    /// Exposed for tests: parse an in-memory FLAC header.
    static func parse(_ data: Data) -> ExtractedMetadata? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            return nil  // not "fLaC"
        }

        var result = ExtractedMetadata()
        var offset = 4
        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let isLast = (header & 0x80) != 0
            let blockType = header & 0x7F
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let bodyStart = offset + 4
            let bodyEnd = bodyStart + length
            guard bodyEnd <= bytes.count else { break }
            let body = bytes[bodyStart..<bodyEnd]

            switch blockType {
            case 4: parseVorbisComment(Array(body), into: &result)
            case 6: parsePicture(Array(body), into: &result)
            default: break
            }

            if isLast { break }
            offset = bodyEnd
        }
        return result.isEmpty ? nil : result
    }

    /// `<u32 LE vendor len><vendor><u32 LE count>( <u32 LE len><FIELD=value> )*`
    private static func parseVorbisComment(_ b: [UInt8], into result: inout ExtractedMetadata) {
        var p = 0
        guard let vendorLen = readUInt32LE(b, &p), advance(&p, by: Int(vendorLen), limit: b.count) else { return }
        guard let count = readUInt32LE(b, &p) else { return }
        for _ in 0..<min(count, 512) {
            guard let len = readUInt32LE(b, &p), p + Int(len) <= b.count else { return }
            let comment = String(decoding: b[p..<p + Int(len)], as: UTF8.self)
            p += Int(len)
            guard let eq = comment.firstIndex(of: "=") else { continue }
            let field = comment[..<eq].uppercased()
            let value = String(comment[comment.index(after: eq)...])
            switch field {
            case "TITLE" where !hasRealText(result.title): result.title = value
            case "ARTIST" where !hasRealText(result.artist): result.artist = value
            case "ALBUM" where !hasRealText(result.album): result.album = value
            default: break
            }
        }
    }

    /// `<u32 BE type><u32 BE mimeLen><mime><u32 BE descLen><desc>`
    /// `<u32 BE w><u32 BE h><u32 BE depth><u32 BE colors><u32 BE dataLen><data>`
    private static func parsePicture(_ b: [UInt8], into result: inout ExtractedMetadata) {
        guard result.artwork == nil else { return }
        var p = 0
        guard let _ = readUInt32BE(b, &p) else { return }                    // picture type
        guard let mimeLen = readUInt32BE(b, &p), advance(&p, by: Int(mimeLen), limit: b.count) else { return }
        guard let descLen = readUInt32BE(b, &p), advance(&p, by: Int(descLen), limit: b.count) else { return }
        guard advance(&p, by: 16, limit: b.count) else { return }            // w, h, depth, colors
        guard let dataLen = readUInt32BE(b, &p), p + Int(dataLen) <= b.count else { return }
        let image = Data(b[p..<p + Int(dataLen)])
        if ImageKind.sniff(image) != nil { result.artwork = image }
    }

    // MARK: byte helpers

    private static func advance(_ p: inout Int, by n: Int, limit: Int) -> Bool {
        guard n >= 0, p + n <= limit else { return false }
        p += n
        return true
    }

    private static func readUInt32LE(_ b: [UInt8], _ p: inout Int) -> UInt32? {
        guard p + 4 <= b.count else { return nil }
        defer { p += 4 }
        return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }

    private static func readUInt32BE(_ b: [UInt8], _ p: inout Int) -> UInt32? {
        guard p + 4 <= b.count else { return nil }
        defer { p += 4 }
        return UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }
}
