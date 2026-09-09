import Foundation

/// Wire format spoken by the SysDVR sysmodule running under Atmosphère.
///
/// Transcribed from the reference client (`Client/Sources/Protocol.cs` and
/// `TCPBridge.cs` in exelix11/SysDVR). Every constant here is a fact about the
/// console, not a choice we get to make — the sysmodule compares these bytes with
/// `memcmp` and hangs up on anything it does not recognise.
enum SysDVR {
    /// The console listens on one port per stream, and each one is an independent
    /// connection with its own handshake.
    enum Port {
        static let video: UInt16 = 9911
        static let audio: UInt16 = 9922
    }

    /// Hardware limits of the Switch encoder. Not configurable: `grc:d` hands out
    /// 720p30 and nothing else, on every model.
    enum Format {
        static let width = 1280
        static let height = 720
        static let frameRate = 30

        static let audioSampleRate: Double = 48000
        static let audioChannels = 2
        /// Signed 16-bit little-endian, interleaved.
        static let audioBytesPerSample = 2
        /// One audio payload before batching, in bytes.
        static let audioPayloadSize = 0x1000
        static let maxAudioBatching = 5
    }

    /// Largest single payload the protocol can carry, used to reject a corrupt
    /// header before we try to allocate whatever length it claims.
    static let maxPayloadSize = 0x54000

    // MARK: - Handshake

    /// The console speaks first, with `SysDVR|NN\0`.
    enum Hello {
        static let size = 10
        static let prefix = "SysDVR|"

        /// Returns the protocol version code, or nil if this is not SysDVR talking.
        static func parse(_ data: Data) -> UInt16? {
            guard data.count == size,
                  let text = String(data: data, encoding: .ascii),
                  text.hasPrefix(prefix),
                  text.hasSuffix("\0")
            else { return nil }

            let digits = Array(text.dropFirst(prefix.count).prefix(2))
            guard digits.count == 2, digits.allSatisfy(\.isASCII) else { return nil }
            return VersionCode.make(digits[0], digits[1])
        }
    }

    /// Version codes travel as the two ASCII digits in memory order. The sysmodule
    /// memcmps them, so on a little-endian host the low byte has to be the first
    /// character — "03" is 0x3330, not 0x3033.
    enum VersionCode {
        static func make(_ high: Character, _ low: Character) -> UInt16 {
            UInt16(high.asciiValue ?? 0) | (UInt16(low.asciiValue ?? 0) << 8)
        }

        static func string(_ code: UInt16) -> String {
            String([Character(UnicodeScalar(UInt8(code & 0xFF))),
                    Character(UnicodeScalar(UInt8(code >> 8)))])
        }

        static let v2 = make("0", "2")
        static let v3 = make("0", "3")

        static func isSupported(_ code: UInt16) -> Bool { code == v2 || code == v3 }
    }

    /// What we ask the console for. 16 bytes on the wire.
    struct HandshakeRequest {
        static let size = 16
        static let magic: UInt32 = 0xAAAA_AAAA
        static let okResult: UInt32 = 6

        var version: UInt16
        var wantsVideo: Bool
        var wantsAudio: Bool
        /// How many audio payloads the console batches per packet (0…4). Higher means
        /// fewer, larger packets: less overhead, more latency.
        var audioBatching: UInt8 = 0
        /// Ask the console to prepend SPS/PPS to every keyframe. Without this a client
        /// that connects mid-stream never learns the codec parameters and shows nothing.
        var injectParameterSets = true
        /// Protocol 3 only: blank the console's own panel while streaming. The picture
        /// is on your face, so the handheld screen is just burning battery.
        var turnOffConsoleScreen = false

        func encoded() -> Data {
            var out = Data(capacity: Self.size)
            out.append(littleEndian: Self.magic)
            out.append(littleEndian: version)

            var meta: UInt8 = 0
            if wantsVideo { meta |= 1 << 0 }
            if wantsAudio { meta |= 1 << 1 }
            out.append(meta)

            var video: UInt8 = 0
            // bit 0 is NAL-hash replay, which we never ask for: it trades bandwidth for
            // the client having to keep a cache of past NALs, and we have bandwidth.
            if injectParameterSets { video |= 1 << 1 }
            out.append(video)

            out.append(audioBatching)

            var features: UInt8 = 0
            if turnOffConsoleScreen, version >= VersionCode.v3 { features |= 1 << 0 }
            out.append(features)

            out.append(Data(repeating: 0, count: 6))  // reserved
            return out
        }

        /// The console's answer is 4 bytes on protocol 2 and 72 on protocol 3; either
        /// way the verdict is the first word.
        static func responseSize(for version: UInt16) -> Int {
            version >= VersionCode.v3 ? 72 : 4
        }
    }

    /// Why the console refused, in its own words.
    enum HandshakeFailure: UInt32 {
        case wrongVersion = 1

        var message: String {
            switch self {
            case .wrongVersion:
                return String(localized: "The console rejected this protocol version. Update SysDVR on the Switch, or update Kagami.")
            }
        }
    }

    // MARK: - Stream packets

    /// Every payload after the handshake is preceded by this. 18 bytes, packed.
    struct PacketHeader {
        static let size = 18
        static let magic: UInt32 = 0xCCCC_CCCC

        var dataSize: Int
        var timestamp: UInt64
        var flags: Flags

        struct Flags: OptionSet {
            let rawValue: UInt8
            static let video = Flags(rawValue: 1 << 0)
            static let audio = Flags(rawValue: 1 << 1)
            static let data = Flags(rawValue: 1 << 2)
            static let hash = Flags(rawValue: 1 << 3)
            static let multiNAL = Flags(rawValue: 1 << 4)
            static let error = Flags(rawValue: 1 << 5)
        }

        /// Returns nil when the magic is wrong or the length is absurd — both mean the
        /// stream is out of sync, and reading `dataSize` bytes would make it worse.
        static func parse(_ data: Data) -> PacketHeader? {
            guard data.count >= size else { return nil }
            let bytes = [UInt8](data)
            guard readUInt32(bytes, 0) == magic else { return nil }

            let length = Int(Int32(bitPattern: readUInt32(bytes, 4)))
            guard length >= 0, length <= maxPayloadSize else { return nil }

            return PacketHeader(
                dataSize: length,
                timestamp: readUInt64(bytes, 8),
                flags: Flags(rawValue: bytes[16]))
        }

        private static func readUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }

        private static func readUInt64(_ b: [UInt8], _ i: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }
        }
    }

    /// Decodes the diagnostic payload the console sends when capture itself failed.
    /// Worth surfacing verbatim: "video capture failed 0x..." is the difference between
    /// a bug here and the console refusing to record a game that blocks capture.
    static func describeError(_ payload: Data) -> String {
        guard payload.count >= 16 else { return String(localized: "Console reported an error.") }
        let words = [UInt8](payload)
        let type = UInt32(words[0]) | UInt32(words[1]) << 8 | UInt32(words[2]) << 16 | UInt32(words[3]) << 24
        let code = UInt32(words[4]) | UInt32(words[5]) << 8 | UInt32(words[6]) << 16 | UInt32(words[7]) << 24

        switch type {
        case 1: return "Video capture failed (0x\(String(code, radix: 16)))"
        case 2, 3: return "Audio capture failed (0x\(String(code, radix: 16)))"
        case 4, 5: return "grc:d refused to start (0x\(String(code, radix: 16)))"
        default: return "Console error type \(type) (0x\(String(code, radix: 16)))"
        }
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
