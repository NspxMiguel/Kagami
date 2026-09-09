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

        static func of(_ nal: Data) -> UInt8 {
            guard let first = nal.first else { return 0 }
            return first & 0x1F
        }
    }

    /// Splits an Annex-B stream into NAL units, start codes removed.
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return [] }

        // Find where each start code begins and ends first, so the payload can be cut
        // as the span between one start code's end and the next one's beginning.
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

        var units: [Data] = []
        for (n, mark) in marks.enumerated() {
            let end = n + 1 < marks.count ? marks[n + 1].code : bytes.count
            guard end > mark.payload else { continue }
            units.append(Data(bytes[mark.payload..<end]))
        }
        return units
    }

    /// Annex-B to length-prefixed, which is what VideoToolbox consumes.
    static func toLengthPrefixed(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        for unit in split(data) {
            out.append(littleEndian: UInt32(unit.count).bigEndian)
            out.append(unit)
        }
        return out
    }

    /// Pulls SPS and PPS out of a frame, returning them alongside the picture data.
    ///
    /// SysDVR is asked to inject parameter sets on every keyframe, so this runs on each
    /// one. Returning the remainder rather than the whole buffer matters: feeding SPS
    /// back into the decoder as if it were a picture makes VideoToolbox fail the frame.
    static func separateParameterSets(_ data: Data) -> (sets: [Data], picture: Data) {
        var sets: [Data] = []
        var picture: [Data] = []

        for unit in split(data) {
            switch NALType.of(unit) {
            case NALType.sps, NALType.pps: sets.append(unit)
            default: picture.append(unit)
            }
        }
        return (sets, join(picture))
    }

    /// True when this access unit can start a decode session on its own.
    static func containsKeyframe(_ data: Data) -> Bool {
        split(data).contains { NALType.of($0) == NALType.idr }
    }

    /// Joins NAL units back into an Annex-B stream, 4-byte start code on each.
    static func join(_ units: [Data]) -> Data {
        var out = Data()
        for unit in units {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(unit)
        }
        return out
    }
}
