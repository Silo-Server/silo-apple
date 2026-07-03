import Foundation

/// Length-prefixed framing for Silo's LAN channels (companion pairing,
/// SiloControl): each payload is sent as a 4-byte big-endian unsigned length
/// followed by that many bytes of JSON. Pure and dependency-free so it is
/// unit-testable in isolation.
enum SiloFrame {
    /// Largest single frame we will encode or accept (1 MiB). Guards against
    /// a peer claiming an absurd length.
    static let maxFrameBytes = 1 << 20

    enum FrameError: Error, Equatable {
        case frameTooLarge(Int)
    }

    /// Prefix `payload` with its big-endian UInt32 length.
    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameBytes else { throw FrameError.frameTooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }
}

/// Accumulates bytes from a stream and yields complete frame payloads as they
/// arrive. Not thread-safe; confine to one connection's receive loop.
struct SiloFrameBuffer {
    private var buffer = Data()

    /// Append newly-received bytes and return every complete payload now
    /// available (possibly zero, possibly several).
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard length <= SiloFrame.maxFrameBytes else {
                throw SiloFrame.FrameError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            let end = buffer.index(start, offsetBy: length)
            payloads.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return payloads
    }
}
