import Foundation

/// Repacking between the two ways H.264 is carried.
///
/// The console sends **Annex-B**: every NAL unit preceded by the `00 00 00 01` start
/// code, which is what survives being cut anywhere and resynchronised — the format a
/// stream needs. VideoToolbox decodes **length-prefixed**: each NAL preceded by its
/// 4-byte size. This is the translation, and it is pure logic, so it can be tested on
/// the Mac instead of only inside the headset.
enum AnnexB {
    /// H.264 NAL types we care about. The type is the low 5 bits of the header byte —
    /// unlike HEVC, where it is 6 bits one position up. Getting this wrong yields a
    /// format description that builds fine and then decodes garbage.
    enum NALType {
        static let idr: UInt8 = 5
        static let sps: UInt8 = 7
        static let pps: UInt8 = 8
    }

    /// Everything `H264Decoder` needs from one access unit, produced by a single pass
    /// over it.
    struct ParsedAccessUnit {
        /// SPS/PPS units, header intact, start codes stripped — what
        /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` wants.
        var parameterSets: [Data] = []
        /// True when this access unit can start a decode session on its own.
        var isKeyframe = false
        /// The picture data alone (parameter sets excluded), already length-prefixed —
        /// what `CMBlockBufferCreateWithMemoryBlock` wants. Ready to hand to
        /// VideoToolbox with no further conversion.
        var lengthPrefixedPicture = Data()
    }

    /// Splits an access unit into NAL units and sorts them in the same pass, building
    /// the length-prefixed picture buffer directly rather than re-joining into Annex-B
    /// first and re-splitting it a moment later.
    ///
    /// This used to be four separate passes over the buffer — `separateParameterSets`
    /// splitting once, `containsKeyframe` splitting the same bytes again just to check
    /// one bit, and `toLengthPrefixed` splitting a *third* time after `join` had spent a
    /// pass rebuilding Annex-B purely so there would be something to split again. On a
    /// 140 KB keyframe — an ordinary size for a busy scene — that was pure overhead the
    /// Mac never felt and the headset's weaker chip did: measured on a real console,
    /// busy scenes in Zelda dropped the actually-decoded frame rate to single digits.
    /// One pass, one set of copies.
    static func parse(_ data: Data) -> ParsedAccessUnit {
        var result = ParsedAccessUnit()
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return result }
        result.lengthPrefixedPicture.reserveCapacity(bytes.count)

        // Find where each start code begins and ends first, so a unit can be cut as the
        // span between one start code's end and the next one's beginning.
        var marks: [(payload: Int, code: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    marks.append((i + 4, i)); i += 4; continue
                }
                if bytes[i + 2] == 1 {
                    marks.append((i + 3, i)); i += 3; continue
                }
            }
            i += 1
        }

        for (n, mark) in marks.enumerated() {
            let end = n + 1 < marks.count ? marks[n + 1].code : bytes.count
            guard end > mark.payload else { continue }
            let nalType = bytes[mark.payload] & 0x1F

            switch nalType {
            case NALType.sps, NALType.pps:
                result.parameterSets.append(Data(bytes[mark.payload..<end]))
            default:
                if nalType == NALType.idr { result.isKeyframe = true }
                let length = end - mark.payload
                withUnsafeBytes(of: UInt32(length).bigEndian) { result.lengthPrefixedPicture.append(contentsOf: $0) }
                result.lengthPrefixedPicture.append(contentsOf: bytes[mark.payload..<end])
            }
        }
        return result
    }
}
