import Foundation

/// Reads Vorbis comments — and cover art carried in them — from an Ogg
/// container: `.ogg` (Vorbis) and `.opus`. AVFoundation plays both but exposes
/// none of their tags on macOS, the same gap `FLACMetadata` fills for FLAC.
///
/// Only the container's first two packets are needed (the codec identification
/// header, then the comment header), so this reassembles just those from the
/// leading pages of the first logical bitstream and hands the payload to the
/// shared `VorbisComment` parser.
enum OggMetadata {
    /// Bytes to read from the front of the file. The comment header — which for
    /// a file with front-cover art carries the whole image — sits right after
    /// the identification header, so 8 MB is ample.
    static let prefixBytes = 8 * 1024 * 1024

    static func read(_ url: URL) -> ExtractedMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: prefixBytes), data.count >= 4 else { return nil }
        return parse(data)
    }

    /// Exposed for tests: parse an in-memory Ogg prefix.
    static func parse(_ data: Data) -> ExtractedMetadata? {
        let bytes = [UInt8](data)
        guard let start = capturePatternOffset(in: bytes) else { return nil }

        // Walk pages, keeping only the first logical bitstream, and split its
        // segment stream into packets (a lacing value < 255 ends a packet).
        var offset = start
        var serial: UInt32?
        var packet: [UInt8] = []
        var packets: [[UInt8]] = []
        var pagesScanned = 0

        pageLoop: while offset + 27 <= bytes.count, pagesScanned < 256 {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67,
                  bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else { break }   // "OggS"

            let segmentCount = Int(bytes[offset + 26])
            let tableStart = offset + 27
            let dataStart = tableStart + segmentCount
            guard dataStart <= bytes.count else { break }
            let pageSerial = le32(bytes, offset + 14)

            var bodyLength = 0
            for i in 0..<segmentCount { bodyLength += Int(bytes[tableStart + i]) }
            let pageEnd = dataStart + bodyLength
            guard pageEnd <= bytes.count else { break }
            pagesScanned += 1

            defer { offset = pageEnd }

            if serial == nil { serial = pageSerial }
            guard pageSerial == serial else { continue }   // a multiplexed stream; ignore

            var cursor = dataStart
            for i in 0..<segmentCount {
                let lacing = Int(bytes[tableStart + i])
                packet.append(contentsOf: bytes[cursor ..< cursor + lacing])
                cursor += lacing
                if lacing < 255 {                          // packet boundary
                    packets.append(packet)
                    packet = []
                    if packets.count >= 2 { break pageLoop }
                }
            }
        }

        guard packets.count >= 2 else { return nil }
        guard let payload = commentPayload(identification: packets[0], comment: packets[1]) else { return nil }

        var result = ExtractedMetadata()
        VorbisComment.parse(payload, into: &result)
        return result.isEmpty ? nil : result
    }

    /// Strips the codec-specific signature from the comment-header packet.
    /// Vorbis: `\x03vorbis`; Opus: `OpusTags`. Returns nil for anything else.
    private static func commentPayload(identification id: [UInt8], comment: [UInt8]) -> [UInt8]? {
        if id.starts(with: [0x01] + Array("vorbis".utf8)) {
            let sig: [UInt8] = [0x03] + Array("vorbis".utf8)
            guard comment.starts(with: sig) else { return nil }
            return Array(comment[sig.count...])
        }
        if id.starts(with: Array("OpusHead".utf8)) {
            let sig = Array("OpusTags".utf8)
            guard comment.starts(with: sig) else { return nil }
            return Array(comment[sig.count...])
        }
        return nil
    }

    /// The first `OggS` in the leading bytes (0 for a well-formed file; a small
    /// offset when a stray ID3 tag was prepended).
    private static func capturePatternOffset(in bytes: [UInt8]) -> Int? {
        let limit = min(bytes.count - 4, 65_536)
        guard limit >= 0 else { return nil }
        for i in 0...limit where bytes[i] == 0x4F && bytes[i + 1] == 0x67
            && bytes[i + 2] == 0x67 && bytes[i + 3] == 0x53 {
            return i
        }
        return nil
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
