import Foundation
import QEQHardware

/// The display channel is independent of MIDI. Only successful, matching ACKs advance pixels.
enum DisplayWire {
    enum Failure: Error, Equatable {
        case malformed
        case unsupported
        case sequence
        case rejected(UInt32)
        case timeout
        case stopped
    }
    enum Kind: UInt8 {
        case hello = 1
        case capabilities
        case begin
        case tile
        case commit
        case ack
        case ping
        case pong
    }
    static let headerSize = 28
    static let maxPayload = 2064
    struct Message: Equatable {
        var kind: Kind
        var flags: UInt16 = 0
        var session: UInt32
        var frame: UInt32 = 0
        var base: UInt32 = 0
        var payload = Data()
        func encoded() -> Data {
            var bytes = Data("QDSP".utf8)
            bytes.append(contentsOf: [1, kind.rawValue])
            bytes.put(flags)
            bytes.put(session)
            bytes.put(frame)
            bytes.put(base)
            bytes.put(UInt32(payload.count))
            bytes.put(DisplayWire.crc(payload, seed: DisplayWire.crc(bytes)))
            bytes.append(payload)
            return bytes
        }
        init(
            kind: Kind, flags: UInt16 = 0, session: UInt32, frame: UInt32 = 0, base: UInt32 = 0, payload: Data = Data()
        ) {
            self.kind = kind
            self.flags = flags
            self.session = session
            self.frame = frame
            self.base = base
            self.payload = payload
        }
        init(bytes: Data) throws {
            guard bytes.count >= headerSize, bytes.prefix(4) == Data("QDSP".utf8), bytes[4] == 1,
                let kind = Kind(rawValue: bytes[5]), bytes.u32(20) <= maxPayload,
                bytes.count == headerSize + Int(bytes.u32(20))
            else { throw Failure.malformed }
            self.kind = kind
            flags = bytes.u16(6)
            session = bytes.u32(8)
            frame = bytes.u32(12)
            base = bytes.u32(16)
            payload = Data(bytes.dropFirst(headerSize))
            guard bytes.u32(24) == DisplayWire.crc(payload, seed: DisplayWire.crc(Data(bytes.prefix(24)))) else {
                throw Failure.malformed
            }
        }
    }
    struct Decoder {
        private var bytes = Data()
        mutating func feed(_ incoming: Data) throws -> [Message] {
            guard bytes.count + incoming.count <= 8192 else { throw Failure.malformed }
            bytes.append(incoming)
            var messages: [Message] = []
            while bytes.count >= headerSize {
                guard bytes.prefix(4) == Data("QDSP".utf8), bytes[4] == 1, bytes.u32(20) <= maxPayload else {
                    throw Failure.malformed
                }
                let length = headerSize + Int(bytes.u32(20))
                guard bytes.count >= length else { break }
                messages.append(try Message(bytes: Data(bytes.prefix(length))))
                bytes = Data(bytes.dropFirst(length))
            }
            return messages
        }
    }
    struct Capabilities {
        let display: HardwareDisplayCapabilities
        let boot: UInt32
        init(_ data: Data) throws {
            guard data.count == 24 else { throw Failure.malformed }
            display = HardwareDisplayCapabilities(
                width: Int(data.u16(0)), height: Int(data.u16(2)),
                format: Int(data[8]), orientation: Int(data[9]), shape: Int(data[10]))
            boot = data.u32(20)
            guard display.supported, data.u16(4) == 32, data.u16(6) == 32, data[11] == 3,
                data.u32(12) == maxPayload
            else { throw Failure.unsupported }
        }
    }
    static func crc(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { qeq_display_crc32($0.baseAddress, $0.count, seed) }
    }
}

extension Data {
    fileprivate mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    fileprivate func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    fileprivate func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

struct DisplayFramePlanner {
    struct Pending {
        let frame: UInt32
        let pixels: Data
        let wire: Data
        let tiles: Int
        let full: Bool
    }
    let capabilities: HardwareDisplayCapabilities
    let session: UInt32
    private(set) var acknowledged: UInt32 = 0
    private(set) var baseline: Data?
    private(set) var pending: Pending?

    mutating func prepare(_ pixels: Data) throws -> Pending? {
        guard pending == nil, acknowledged < UInt32.max else { throw DisplayWire.Failure.sequence }
        guard capabilities.supported, pixels.count == capabilities.width * capabilities.height * 2 else {
            throw DisplayWire.Failure.malformed
        }
        let frame = acknowledged + 1
        let full = baseline == nil
        var tileMessages = Data()
        var tileCount = 0
        for y in stride(from: 0, to: capabilities.height, by: 32) {
            for x in stride(from: 0, to: capabilities.width, by: 32) {
                let width = min(32, capabilities.width - x)
                let height = min(32, capabilities.height - y)
                var raw = Data(capacity: width * height * 2)
                var changed = full
                for row in y..<(y + height) {
                    let start = (row * capabilities.width + x) * 2
                    let range = start..<(start + width * 2)
                    raw.append(pixels.subdata(in: range))
                    if !changed, let baseline, pixels[range] != baseline[range] { changed = true }
                }
                guard changed else { continue }
                var compressed = Data(count: raw.count)  // Only keep compression smaller than raw.
                let count = raw.withUnsafeBytes { source in
                    compressed.withUnsafeMutableBytes { target in
                        qeq_lz4_compress(
                            source.baseAddress, Int32(source.count), target.baseAddress, Int32(target.count))
                    }
                }
                let useLZ4 = count > 0 && count < raw.count
                if useLZ4 { compressed.count = Int(count) }
                var payload = Data()
                payload.put(UInt16(x))
                payload.put(UInt16(y))
                payload.put(UInt16(width))
                payload.put(UInt16(height))
                payload.append(contentsOf: [useLZ4 ? 1 : 0, 0])
                payload.put(UInt16(raw.count))
                payload.put(DisplayWire.crc(raw))
                payload.append(useLZ4 ? compressed : raw)
                tileMessages.append(
                    DisplayWire.Message(
                        kind: .tile, session: session, frame: frame,
                        base: full ? 0 : acknowledged, payload: payload
                    ).encoded())
                tileCount += 1
            }
        }
        guard tileCount > 0 else { return nil }
        var count = Data()
        count.put(UInt16(tileCount))
        var wire = DisplayWire.Message(
            kind: .begin, flags: full ? 1 : 0, session: session, frame: frame,
            base: full ? 0 : acknowledged, payload: count
        ).encoded()
        wire.append(tileMessages)
        wire.append(
            DisplayWire.Message(kind: .commit, session: session, frame: frame, base: full ? 0 : acknowledged).encoded())
        let prepared = Pending(frame: frame, pixels: pixels, wire: wire, tiles: tileCount, full: full)
        pending = prepared
        return prepared
    }
    mutating func accept(_ ack: DisplayWire.Message) throws {
        guard let pending, ack.kind == .ack, ack.flags == 0, ack.session == session,
            ack.frame == pending.frame, ack.base == pending.frame, ack.payload.count == 32
        else { throw DisplayWire.Failure.sequence }
        guard ack.payload.u32(0) == 0 else { throw DisplayWire.Failure.rejected(ack.payload.u32(0)) }
        guard ack.payload.u32(16) == pending.tiles, ack.payload.u32(20) == pending.wire.count else {
            throw DisplayWire.Failure.malformed
        }
        acknowledged = pending.frame
        baseline = pending.pixels
        self.pending = nil
    }
    func validatePong(_ pong: DisplayWire.Message) throws {
        guard pong.kind == .pong, pong.flags == 0, pong.session == session, pong.frame == acknowledged,
            pong.base == acknowledged, pong.payload.count == 32, pong.payload.u32(0) == 0
        else { throw DisplayWire.Failure.sequence }
    }
}
