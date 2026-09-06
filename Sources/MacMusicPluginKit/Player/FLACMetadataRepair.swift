import Foundation

/// Works around Core Audio's strict FLAC metadata parser.
///
/// `ExtAudioFileOpenURL` (what `AVAudioFile(forReading:)` calls) rejects the
/// whole file with `kAudioFileInvalidFileError` — OSStatus 1685348671, `'dta?'`
/// — the instant it meets a metadata block whose type is out of spec: 7…126 are
/// reserved and 127 is invalid. libFLAC, ffmpeg, VLC and the SDL backend this
/// port replaces all skip such a block and play the audio, so a file that plays
/// everywhere else fails only here.
///
/// The common cause is a `PADDING` block header that lost a bit somewhere in its
/// travels — `0x81` (last-block, `PADDING`) becomes `0xFF` (last-block, type
/// 127) — while the audio frames stay intact.
///
/// `patches(forHeader:)` walks the block chain and, for every bad block type,
/// yields the one header byte to rewrite to `PADDING` (type 1). Lengths,
/// offsets and the last-block flag are left exactly as they were, so a repaired
/// copy differs from the original only in those bytes Core Audio choked on.
enum FLACMetadataRepair {
    /// How far into the file the metadata chain is allowed to reach. Audio
    /// frames follow the metadata; even a full-resolution embedded cover keeps
    /// the blocks far under this. Matches `FLACMetadata.prefixBytes`.
    static let scanLimit = 8 * 1024 * 1024

    struct Patch: Equatable { let offset: Int; let byte: UInt8 }

    /// The header-byte rewrites needed to make `bytes` (the front of a FLAC
    /// file) acceptable to Core Audio. Empty when `bytes` is not FLAC, the block
    /// chain cannot be walked to its terminating block, or every block type is
    /// already valid.
    static func patches(forHeader bytes: [UInt8]) -> [Patch] {
        guard bytes.count >= 8,
              bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            return []  // not "fLaC"
        }

        var found: [Patch] = []
        var offset = 4
        var steps = 0
        while offset + 4 <= bytes.count {
            steps += 1
            if steps > 4096 { return [] }  // pathological chain — bail rather than guess

            let header = bytes[offset]
            let isLast = (header & 0x80) != 0
            let blockType = header & 0x7F
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])

            if blockType > 6 {
                found.append(Patch(offset: offset, byte: (header & 0x80) | 0x01))
            }

            offset += 4 + length
            if isLast {
                // A well-formed chain ends on a real block whose body lies
                // within what we read (the audio frames come next). If the
                // arithmetic overran, we mis-parsed — touch nothing.
                return offset <= bytes.count ? found : []
            }
            if offset > bytes.count { return [] }
        }
        return []  // never reached the last-block flag within the scanned region
    }

    /// If `url` is a FLAC that Core Audio would reject only for an out-of-spec
    /// metadata block, writes a byte-identical copy with that block's header
    /// fixed to `destination` and returns it. Returns `nil` when no repair is
    /// possible or needed.
    ///
    /// The copy is made with `copyItem` (a cheap clone on APFS) and patched in
    /// place, so a multi-hundred-MB lossless file costs no large allocation.
    static func repairedCopy(of url: URL, at destination: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let head: Data = {
            defer { try? handle.close() }
            return (try? handle.read(upToCount: scanLimit)) ?? Data()
        }()
        let patchList = patches(forHeader: [UInt8](head))
        guard !patchList.isEmpty else { return nil }

        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).flac")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: tmp)
        guard (try? fm.copyItem(at: url, to: tmp)) != nil else { return nil }

        do {
            let out = try FileHandle(forWritingTo: tmp)
            defer { try? out.close() }
            for patch in patchList {
                try out.seek(toOffset: UInt64(patch.offset))
                try out.write(contentsOf: Data([patch.byte]))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            return nil
        }

        // Unlink first so an `AVAudioFile` still holding the previous repair
        // keeps its inode; only this serialized load path writes here.
        try? fm.removeItem(at: destination)
        guard (try? fm.moveItem(at: tmp, to: destination)) != nil else {
            try? fm.removeItem(at: tmp)
            return nil
        }
        return destination
    }
}
