import Foundation
import Compression

// COMPRESSION_ZSTD is not exposed in the public Compression headers but is
// supported at runtime on iOS 16+. Raw value matches the internal enum.
private let COMPRESSION_ZSTD = compression_algorithm(rawValue: 0xB03)

// MARK: - Constants

let frameHeaderSize = 15
let maxPayload = 65536
let maxFrame = frameHeaderSize + maxPayload
let compressThreshold = 256
let flagCompressed: UInt16 = 0x0001

// MARK: - Frame Type

enum FrameType: UInt8 {
    case data = 0x01
    case resize = 0x02
    case heartbeat = 0x03
    case close = 0x04
    case scrollback = 0x05
    case windowUpdate = 0x06
}

// MARK: - Frame

struct Frame {
    let type_: FrameType
    let sequence: UInt64
    var payload: Data

    // Convenience constructors

    static func data(seq: UInt64, payload: Data) -> Frame {
        Frame(type_: .data, sequence: seq, payload: payload)
    }

    static func resize(seq: UInt64, cols: UInt16, rows: UInt16) -> Frame {
        var payload = Data(capacity: 4)
        payload.appendBigEndian(cols)
        payload.appendBigEndian(rows)
        return Frame(type_: .resize, sequence: seq, payload: payload)
    }

    static func heartbeat(seq: UInt64) -> Frame {
        Frame(type_: .heartbeat, sequence: seq, payload: Data())
    }

    static func close(seq: UInt64) -> Frame {
        Frame(type_: .close, sequence: seq, payload: Data())
    }

    static func scrollback(seq: UInt64, payload: Data) -> Frame {
        Frame(type_: .scrollback, sequence: seq, payload: payload)
    }

    static func windowUpdate(seq: UInt64, window: UInt64) -> Frame {
        var payload = Data(capacity: 8)
        payload.appendBigEndian(window)
        return Frame(type_: .windowUpdate, sequence: seq, payload: payload)
    }

    // Parsers

    func parseResize() -> (cols: UInt16, rows: UInt16)? {
        guard type_ == .resize, payload.count >= 4 else { return nil }
        let cols = payload.readBigEndianUInt16(at: 0)
        let rows = payload.readBigEndianUInt16(at: 2)
        return (cols, rows)
    }

    func parseWindowUpdate() -> UInt64? {
        guard type_ == .windowUpdate, payload.count >= 8 else { return nil }
        return payload.readBigEndianUInt64(at: 0)
    }
}

// MARK: - Encoder

enum FrameCodecError: Error {
    case payloadTooLarge(Int)
    case incompleteHeader
    case incompletePayload
    case unknownType(UInt8)
    case compressionFailed
    case decompressionFailed
}

func encodeFrame(_ frame: Frame, compress: Bool = false) throws -> Data {
    var payloadBytes = frame.payload
    var flags: UInt16 = 0

    if compress && frame.payload.count > compressThreshold {
        if let compressed = compressZstd(frame.payload), compressed.count < frame.payload.count {
            payloadBytes = compressed
            flags |= flagCompressed
        }
    }

    guard payloadBytes.count <= maxPayload else {
        throw FrameCodecError.payloadTooLarge(payloadBytes.count)
    }

    var buf = Data(capacity: frameHeaderSize + payloadBytes.count)
    buf.append(frame.type_.rawValue)
    buf.appendBigEndian(UInt32(payloadBytes.count))
    buf.appendBigEndian(frame.sequence)
    buf.appendBigEndian(flags)
    buf.append(payloadBytes)

    return buf
}

// MARK: - Decoder

/// Decode a single frame from the start of `data`.
/// Returns the frame and number of bytes consumed, or nil if not enough data.
func decodeFrame(_ data: Data) throws -> (Frame, Int)? {
    guard data.count >= frameHeaderSize else { return nil }

    let typeByte = data[data.startIndex]
    guard let frameType = FrameType(rawValue: typeByte) else {
        throw FrameCodecError.unknownType(typeByte)
    }

    let payloadLen = Int(data.readBigEndianUInt32(at: 1))
    let sequence = data.readBigEndianUInt64(at: 5)
    let flags = data.readBigEndianUInt16(at: 13)

    guard payloadLen <= maxPayload else {
        throw FrameCodecError.payloadTooLarge(payloadLen)
    }

    let total = frameHeaderSize + payloadLen
    guard data.count >= total else { return nil }

    let rawPayload = data.subdata(in: (data.startIndex + frameHeaderSize)..<(data.startIndex + total))

    let payload: Data
    if flags & flagCompressed != 0 {
        guard let decompressed = decompressZstd(rawPayload) else {
            throw FrameCodecError.decompressionFailed
        }
        payload = decompressed
    } else {
        payload = rawPayload
    }

    return (Frame(type_: frameType, sequence: sequence, payload: payload), total)
}

// MARK: - Streaming Decoder

class FrameDecoder {
    private var buffer = Data()
    /// Read offset — bytes before this have been consumed
    private var offset = 0
    /// Max buffered bytes before dropping data (1MB)
    private let maxBufferSize = 1_048_576

    func feed(_ data: Data) {
        // Compact if consumed portion is large (>32KB) to prevent unbounded growth
        if offset > 32768 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        buffer.append(data)
        if buffer.count > maxBufferSize {
            // Drop oldest data to prevent OOM from malicious/corrupt stream
            let excess = buffer.count - maxBufferSize
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + excess))
            offset = 0
        }
    }

    func decodeNext() throws -> Frame? {
        let remaining = buffer.subdata(in: (buffer.startIndex + offset)..<buffer.endIndex)
        guard let (frame, consumed) = try decodeFrame(remaining) else { return nil }
        offset += consumed
        return frame
    }

    func reset() {
        buffer.removeAll()
        offset = 0
    }
}

// MARK: - Control Messages (length-prefixed JSON)

enum ControlCodec {
    static func encode(_ json: Data) -> Data {
        var buf = Data(capacity: 4 + json.count)
        buf.appendBigEndian(UInt32(json.count))
        buf.append(json)
        return buf
    }

    static func decode(_ data: Data) -> (json: Data, consumed: Int)? {
        guard data.count >= 4 else { return nil }
        let len = Int(data.readBigEndianUInt32(at: 0))
        let total = 4 + len
        guard data.count >= total else { return nil }
        let json = data.subdata(in: (data.startIndex + 4)..<(data.startIndex + total))
        return (json, total)
    }
}

// MARK: - Zstd Compression (using Apple's Compression framework as fallback)

// Note: Apple's Compression framework supports ZSTD on iOS 16+.
// We use it directly rather than bundling a zstd library.

private func compressZstd(_ data: Data) -> Data? {
    data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Data? in
        guard let source = rawBuffer.baseAddress else { return nil }
        let destSize = data.count + 512 // zstd needs some overhead
        var dest = Data(count: destSize)
        let compressedSize = dest.withUnsafeMutableBytes { (destBuffer: UnsafeMutableRawBufferPointer) -> Int in
            guard let destPtr = destBuffer.baseAddress else { return 0 }
            return compression_encode_buffer(
                destPtr.assumingMemoryBound(to: UInt8.self), destSize,
                source.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZSTD
            )
        }
        guard compressedSize > 0 else { return nil }
        return dest.prefix(compressedSize)
    }
}

private func decompressZstd(_ data: Data) -> Data? {
    data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Data? in
        guard let source = rawBuffer.baseAddress else { return nil }
        let destSize = maxPayload
        var dest = Data(count: destSize)
        let decompressedSize = dest.withUnsafeMutableBytes { (destBuffer: UnsafeMutableRawBufferPointer) -> Int in
            guard let destPtr = destBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destPtr.assumingMemoryBound(to: UInt8.self), destSize,
                source.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZSTD
            )
        }
        guard decompressedSize > 0 else { return nil }
        return dest.prefix(decompressedSize)
    }
}

// MARK: - Data Extensions (Big Endian)

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var big = value.bigEndian
        append(UnsafeBufferPointer(start: &big, count: 1))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        append(UnsafeBufferPointer(start: &big, count: 1))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var big = value.bigEndian
        append(UnsafeBufferPointer(start: &big, count: 1))
    }

    func readBigEndianUInt16(at offset: Int) -> UInt16 {
        let idx = startIndex + offset
        return UInt16(self[idx]) << 8 | UInt16(self[idx + 1])
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let idx = startIndex + offset
        return UInt32(self[idx]) << 24 | UInt32(self[idx + 1]) << 16
            | UInt32(self[idx + 2]) << 8 | UInt32(self[idx + 3])
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        let idx = startIndex + offset
        return UInt64(self[idx]) << 56 | UInt64(self[idx + 1]) << 48
            | UInt64(self[idx + 2]) << 40 | UInt64(self[idx + 3]) << 32
            | UInt64(self[idx + 4]) << 24 | UInt64(self[idx + 5]) << 16
            | UInt64(self[idx + 6]) << 8 | UInt64(self[idx + 7])
    }
}
