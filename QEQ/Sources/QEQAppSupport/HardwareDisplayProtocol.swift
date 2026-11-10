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
        case rectangleBatch = 11
    }
    static let headerSize = 28
    static let maxPayload = 2064
    static let maxBatchBytes = 8192
    static let maxBatchRectangles = 8
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
        let partialTiles: Bool
        let rectangleBatches: Bool
        init(_ data: Data) throws {
            guard data.count == 24 else { throw Failure.malformed }
            display = HardwareDisplayCapabilities(
                width: Int(data.u16(0)), height: Int(data.u16(2)),
                format: Int(data[8]), orientation: Int(data[9]), shape: Int(data[10]))
            boot = data.u32(20)
            partialTiles = data[11] & 4 != 0
            rectangleBatches = data[11] & 8 != 0
            guard display.supported, data.u16(4) == 32, data.u16(6) == 32, [3, 7, 15].contains(data[11]),
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

// Queue-confined with its planner. Copies of a planner share scratch codec state,
// but every invocation resets history. Compression never depends on an earlier packet.
private final class DisplayTileEncoder {
    let handle = qeq_lz4_encoder_create()
    deinit { qeq_lz4_encoder_destroy(handle) }
}

struct DisplayFramePlanner {
    struct Pending {
        let frame: UInt32
        let pixels: Data
        let wire: Data
        let tiles: Int
        let batches: Int
        let full: Bool
    }
    let capabilities: HardwareDisplayCapabilities
    let session: UInt32
    private struct Rectangle {
        let x: UInt16
        let y: UInt16
        let width: UInt16
        let height: UInt16
        let pixels: Data

        func appendGeometry(to data: inout Data) {
            data.put(x)
            data.put(y)
            data.put(width)
            data.put(height)
        }
    }

    var partialTiles = false
    var rectangleBatches = false
    private(set) var acknowledged: UInt32 = 0
    private(set) var baseline: Data?
    private(set) var pending: Pending?
    private let encoder = DisplayTileEncoder()

    mutating func prepare(_ pixels: Data, forceFull: Bool = false) throws -> Pending? {
        guard pending == nil, acknowledged < UInt32.max else { throw DisplayWire.Failure.sequence }
        guard capabilities.supported, pixels.count == capabilities.width * capabilities.height * 2 else {
            throw DisplayWire.Failure.malformed
        }
        let frame = acknowledged + 1
        let full = baseline == nil || forceFull
        let base = full ? 0 : acknowledged
        let useBatches = rectangleBatches
        let partial = partialTiles && !full
        let encoderHandle = encoder.handle
        let session = self.session
        var tileMessages = Data()
        var tileCount = 0
        var batchCount = 0
        var group: [Rectangle] = []
        var groupBytes = 0
        var compressed = Data(count: Int(qeq_lz4_compress_bound(useBatches ? 8192 : 2048)))

        func compress(_ raw: Data) -> Int {
            let count = raw.withUnsafeBytes { source in
                compressed.withUnsafeMutableBytes { target in
                    qeq_lz4_encoder_compress(
                        encoderHandle, source.baseAddress, Int32(source.count), target.baseAddress,
                        Int32(target.count))
                }
            }
            return count > 0 && count < raw.count ? Int(count) : 0
        }

        func appendTile(_ rect: Rectangle) {
            let count = compress(rect.pixels)
            var payload = Data()
            rect.appendGeometry(to: &payload)
            payload.append(contentsOf: [count > 0 ? 1 : 0, partial ? 1 : 0])
            payload.put(UInt16(rect.pixels.count))
            payload.put(DisplayWire.crc(rect.pixels))
            if count > 0 { payload.append(compressed.prefix(count)) } else { payload.append(rect.pixels) }
            tileMessages.append(
                DisplayWire.Message(kind: .tile, session: session, frame: frame, base: base, payload: payload).encoded()
            )
        }

        func appendGroup(_ rectangles: ArraySlice<Rectangle>) {
            if rectangles.count == 1 {
                appendTile(rectangles[rectangles.startIndex])
                return
            }
            var raw = Data()
            raw.reserveCapacity(rectangles.reduce(0) { $0 + $1.pixels.count })
            for rect in rectangles { raw.append(rect.pixels) }
            let count = compress(raw)
            let bodySize = count > 0 ? count : raw.count
            if 8 + rectangles.count * 8 + bodySize > DisplayWire.maxPayload {
                let middle = rectangles.startIndex + rectangles.count / 2
                appendGroup(rectangles[..<middle])
                appendGroup(rectangles[middle...])
                return
            }
            var payload = Data([UInt8(rectangles.count), count > 0 ? 1 : 0])
            payload.put(UInt16(raw.count))
            payload.put(DisplayWire.crc(raw))
            for rect in rectangles { rect.appendGeometry(to: &payload) }
            if count > 0 { payload.append(compressed.prefix(count)) } else { payload.append(raw) }
            tileMessages.append(
                DisplayWire.Message(
                    kind: .rectangleBatch, session: session, frame: frame, base: base, payload: payload
                ).encoded())
            batchCount += 1
        }
        for y in stride(from: 0, to: capabilities.height, by: 32) {
            for x in stride(from: 0, to: capabilities.width, by: 32) {
                var left = x
                var top = y
                var width = min(32, capabilities.width - x)
                var height = min(32, capabilities.height - y)
                var changed = full
                if !changed, let baseline {
                    for row in y..<(y + height) {
                        let start = (row * capabilities.width + x) * 2
                        let range = start..<(start + width * 2)
                        if pixels[range] != baseline[range] {
                            changed = true
                            break
                        }
                    }
                }
                guard changed else { continue }
                if partialTiles && !full, let baseline {
                    var minX = width
                    var minY = height
                    var maxX = 0
                    var maxY = 0
                    pixels.withUnsafeBytes { current in
                        baseline.withUnsafeBytes { old in
                            for row in 0..<height {
                                let offset = ((y + row) * capabilities.width + x) * 2
                                if memcmp(current.baseAddress! + offset, old.baseAddress! + offset, width * 2) == 0 {
                                    continue
                                }
                                minY = min(minY, row)
                                maxY = row
                                for column in 0..<width {
                                    let i = offset + column * 2
                                    if current.loadUnaligned(fromByteOffset: i, as: UInt16.self)
                                        != old.loadUnaligned(fromByteOffset: i, as: UInt16.self)
                                    {
                                        minX = min(minX, column)
                                        maxX = max(maxX, column)
                                    }
                                }
                            }
                        }
                    }
                    left += minX
                    top += minY
                    width = maxX - minX + 1
                    height = maxY - minY + 1
                }
                var raw = Data(count: width * height * 2)
                raw.withUnsafeMutableBytes { target in
                    pixels.withUnsafeBytes { source in
                        for row in 0..<height {
                            let start = ((top + row) * capabilities.width + left) * 2
                            target.baseAddress!.advanced(by: row * width * 2)
                                .copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: width * 2)
                        }
                    }
                }
                let rect = Rectangle(
                    x: UInt16(left), y: UInt16(top), width: UInt16(width), height: UInt16(height), pixels: raw)
                if useBatches {
                    if group.count == DisplayWire.maxBatchRectangles
                        || groupBytes + raw.count > DisplayWire.maxBatchBytes
                    {
                        appendGroup(group[...])
                        group.removeAll(keepingCapacity: true)
                        groupBytes = 0
                    }
                    group.append(rect)
                    groupBytes += raw.count
                } else {
                    appendTile(rect)
                }
                tileCount += 1
            }
        }
        guard tileCount > 0 else { return nil }
        if !group.isEmpty { appendGroup(group[...]) }
        var count = Data()
        count.put(UInt16(tileCount))
        var wire = DisplayWire.Message(
            kind: .begin, flags: full ? 1 : 0, session: session, frame: frame,
            base: full ? 0 : acknowledged, payload: count
        ).encoded()
        wire.append(tileMessages)
        wire.append(
            DisplayWire.Message(kind: .commit, session: session, frame: frame, base: full ? 0 : acknowledged).encoded())
        let prepared = Pending(
            frame: frame, pixels: pixels, wire: wire, tiles: tileCount, batches: batchCount, full: full)
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
