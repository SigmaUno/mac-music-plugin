import Foundation
@testable import MacMusicPluginKit

/// `FLACMetadataRepair` — the workaround for Core Audio rejecting FLACs whose
/// metadata chain carries an out-of-spec block type (the real-world case: a
/// `PADDING` header corrupted from `0x81` to `0xFF`, i.e. block type 127).
enum FLACRepairTests {

    /// `fLaC` + a STREAMINFO block (type 0, 34 zero bytes) + a final block with
    /// the given header byte and an 8-byte body.
    private static func flac(finalHeaderByte: UInt8, finalLength: Int = 8) -> [UInt8] {
        var b: [UInt8] = [0x66, 0x4C, 0x61, 0x43]        // "fLaC"
        b += [0x00, 0x00, 0x00, 0x22]                    // STREAMINFO, not last, len 34
        b += [UInt8](repeating: 0, count: 34)
        b += [finalHeaderByte,
              UInt8((finalLength >> 16) & 0xFF), UInt8((finalLength >> 8) & 0xFF), UInt8(finalLength & 0xFF)]
        b += [UInt8](repeating: 0, count: max(0, finalLength))
        return b
    }

    static func register() {
        Harness.test("patches: rewrites an invalid block type to last-block PADDING") {
            let patches = FLACMetadataRepair.patches(forHeader: flac(finalHeaderByte: 0xFF))
            Harness.expectEqual(patches.count, 1, "one bad block")
            Harness.expectEqual(patches.first?.offset, 42, "header sits right after fLaC + STREAMINFO")
            Harness.expectEqual(patches.first?.byte, 0x81, "PADDING (1) with the last-block flag kept")
        }

        Harness.test("patches: reserved types 7…126 are repaired too") {
            // 0x80 | 40 = last-block, reserved type 40.
            Harness.expectEqual(FLACMetadataRepair.patches(forHeader: flac(finalHeaderByte: 0xA8)).first?.byte,
                                0x81, "reserved type coerced to PADDING")
        }

        Harness.test("patches: a well-formed chain needs no repair") {
            Harness.expect(FLACMetadataRepair.patches(forHeader: flac(finalHeaderByte: 0x81)).isEmpty,
                           "last-block PADDING is fine")
            // STREAMINFO alone, marked last.
            var lone: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x80, 0x00, 0x00, 0x22]
            lone += [UInt8](repeating: 0, count: 34)
            Harness.expect(FLACMetadataRepair.patches(forHeader: lone).isEmpty, "single last STREAMINFO is fine")
        }

        Harness.test("patches: refuses to guess on a malformed chain") {
            Harness.expect(FLACMetadataRepair.patches(forHeader: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]).isEmpty,
                           "not fLaC")
            // Bad block whose declared length runs past what was read: we
            // mis-parsed, touch nothing.
            var overrun: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22]
            overrun += [UInt8](repeating: 0, count: 34)
            overrun += [0xFF, 0x00, 0xFF, 0x00]   // type 127, declares 65280 bytes, body absent
            Harness.expect(FLACMetadataRepair.patches(forHeader: overrun).isEmpty,
                           "overrunning block length => no patch")
            // Chain that never sets the last-block flag before EOF.
            var openChain: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22]
            openChain += [UInt8](repeating: 0, count: 34)
            Harness.expect(FLACMetadataRepair.patches(forHeader: openChain).isEmpty, "no terminating block => no patch")
        }

        Harness.test("repairedCopy: patches a bad file, leaves a healthy one alone") {
            let (dir, cleanup) = Harness.tempDir("flac-repair")
            defer { cleanup() }

            let broken = dir.appendingPathComponent("broken.flac")
            try Data(flac(finalHeaderByte: 0xFF)).write(to: broken)
            let dest = dir.appendingPathComponent("out/coreaudio-repair.flac")

            guard let repaired = FLACMetadataRepair.repairedCopy(of: broken, at: dest) else {
                Harness.expect(false, "expected a repaired copy"); return
            }
            Harness.expectEqual(repaired, dest)
            let fixed = [UInt8](try Data(contentsOf: repaired))
            var expected = flac(finalHeaderByte: 0xFF)
            expected[42] = 0x81
            Harness.expect(fixed == expected, "only the bad header byte changed")

            let healthy = dir.appendingPathComponent("healthy.flac")
            try Data(flac(finalHeaderByte: 0x81)).write(to: healthy)
            Harness.expect(FLACMetadataRepair.repairedCopy(of: healthy, at: dest) == nil,
                           "a healthy FLAC yields no copy")
        }
    }
}
