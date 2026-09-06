import Foundation

/// The Vorbis comment list — a vendor string followed by `FIELD=value` pairs —
/// shared by FLAC (its `VORBIS_COMMENT` metadata block) and Ogg (the Vorbis /
/// Opus comment-header packet). Also decodes cover art carried *as* a comment:
/// `METADATA_BLOCK_PICTURE` (base64 of a FLAC PICTURE block, how Ogg files store
/// art) and the legacy `COVERART` (base64 of a raw image).
enum VorbisComment {
    /// `b` starts at the 32-bit LE vendor length. Fills title/artist/album and,
    /// unless artwork is already set, the cover image. Trailing bytes (e.g. a
    /// Vorbis framing bit) are ignored.
    static func parse(_ b: [UInt8], into result: inout ExtractedMetadata) {
        var p = 0
        guard let vendorLen = readUInt32LE(b, &p), advance(&p, by: Int(vendorLen), limit: b.count) else { return }
        guard let count = readUInt32LE(b, &p) else { return }

        for _ in 0..<min(count, 1024) {
            guard let len = readUInt32LE(b, &p), len <= UInt32(b.count), p + Int(len) <= b.count else { return }
            let raw = Array(b[p ..< p + Int(len)])
            p += Int(len)
            guard let eq = raw.firstIndex(of: 0x3D) else { continue }   // '='
            let field = String(decoding: raw[..<eq], as: UTF8.self).uppercased()
            let valueBytes = raw[(eq + 1)...]

            switch field {
            case "TITLE" where !hasRealText(result.title):
                result.title = String(decoding: valueBytes, as: UTF8.self)
            case "ARTIST" where !hasRealText(result.artist):
                result.artist = String(decoding: valueBytes, as: UTF8.self)
            case "ALBUM" where !hasRealText(result.album):
                result.album = String(decoding: valueBytes, as: UTF8.self)
            case "METADATA_BLOCK_PICTURE" where result.artwork == nil:
                if let decoded = base64(valueBytes) {
                    parsePicture(Array(decoded), into: &result)
                }
            case "COVERART" where result.artwork == nil:
                if let decoded = base64(valueBytes), ImageKind.sniff(decoded) != nil {
                    result.artwork = decoded
                }
            default:
                break
            }
        }
    }

    /// A FLAC `PICTURE` block (also what `METADATA_BLOCK_PICTURE` base64-wraps):
    /// `<u32 BE type><u32 BE mimeLen><mime><u32 BE descLen><desc>`
    /// `<u32 BE w><u32 BE h><u32 BE depth><u32 BE colors><u32 BE dataLen><data>`.
    static func parsePicture(_ b: [UInt8], into result: inout ExtractedMetadata) {
        guard result.artwork == nil else { return }
        var p = 0
        guard readUInt32BE(b, &p) != nil else { return }                              // picture type
        guard let mimeLen = readUInt32BE(b, &p), advance(&p, by: Int(mimeLen), limit: b.count) else { return }
        guard let descLen = readUInt32BE(b, &p), advance(&p, by: Int(descLen), limit: b.count) else { return }
        guard advance(&p, by: 16, limit: b.count) else { return }                     // w, h, depth, colours
        guard let dataLen = readUInt32BE(b, &p), dataLen <= UInt32(b.count), p + Int(dataLen) <= b.count else { return }
        let image = Data(b[p ..< p + Int(dataLen)])
        if ImageKind.sniff(image) != nil { result.artwork = image }
    }

    // MARK: byte helpers

    private static func base64(_ bytes: ArraySlice<UInt8>) -> Data? {
        Data(base64Encoded: Data(bytes), options: .ignoreUnknownCharacters)
    }

    static func advance(_ p: inout Int, by n: Int, limit: Int) -> Bool {
        guard n >= 0, p + n <= limit else { return false }
        p += n
        return true
    }

    static func readUInt32LE(_ b: [UInt8], _ p: inout Int) -> UInt32? {
        guard p + 4 <= b.count else { return nil }
        defer { p += 4 }
        return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }

    static func readUInt32BE(_ b: [UInt8], _ p: inout Int) -> UInt32? {
        guard p + 4 <= b.count else { return nil }
        defer { p += 4 }
        return UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }
}
