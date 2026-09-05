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
            let body = Array(bytes[bodyStart ..< bodyEnd])

            switch blockType {
            case 4: VorbisComment.parse(body, into: &result)
            case 6: VorbisComment.parsePicture(body, into: &result)
            default: break
            }

            if isLast { break }
            offset = bodyEnd
        }
        return result.isEmpty ? nil : result
    }
}
