import DisplayReceiverTestSupport
import Foundation
import Metal
import QEQHardware
import Testing
import os

@testable import QEQAppSupport

private final class ReceiverPort: DisplayBulkPort, @unchecked Sendable {
    struct State: @unchecked Sendable {
        var handle: OpaquePointer
        var writes: [DisplayWire.Message] = []
        var dropACK = false
        var holdACK = false
        var holding = false
        var closed = false
    }
    let state = OSAllocatedUnfairLock(initialState: State(handle: qeq_test_receiver_create()!))
    let waiting = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    deinit { state.withLock { qeq_test_receiver_destroy($0.handle) } }
    func write(_ data: Data) throws {
        try state.withLock { state in
            var decoder = DisplayWire.Decoder()
            for offset in stride(from: 0, to: data.count, by: 1000) {
                let chunk = data.subdata(in: offset..<min(offset + 1000, data.count))
                state.writes += try decoder.feed(chunk)
                chunk.withUnsafeBytes {
                    qeq_test_receiver_feed(state.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                }
            }
            if state.writes.last?.kind == .commit, state.holdACK {
                state.holding = true
                state.holdACK = false
            }
        }
    }
    func read(timeout: TimeInterval) throws -> Data {
        let hold = state.withLock { state -> Bool in
            let holding = state.holding
            state.holding = false
            return holding
        }
        if hold {
            waiting.signal()
            guard release.wait(timeout: .now() + 2) == .success else { throw DisplayWire.Failure.timeout }
        }
        return try state.withLock { state in
            if state.dropACK, state.writes.last?.kind == .commit {
                var discarded = [UInt8](repeating: 0, count: 4096)
                _ = qeq_test_receiver_read(state.handle, &discarded, discarded.count)
                state.dropACK = false
                throw DisplayWire.Failure.timeout
            }
            var bytes = [UInt8](repeating: 0, count: 7)  // Deliberately fragment all device replies.
            let count = qeq_test_receiver_read(state.handle, &bytes, bytes.count)
            guard count > 0 else { throw DisplayWire.Failure.timeout }
            return Data(bytes.prefix(count))
        }
    }
    func close() { state.withLock { $0.closed = true } }
    var pixelCRC: UInt32 { state.withLock { qeq_test_receiver_pixels_crc($0.handle) } }
    var writes: [DisplayWire.Message] { state.withLock { $0.writes } }
}

@Test func nativeDisplaySenderMatchesActualFirmwarePixelsAndReconnectBaseline() throws {
    let port = ReceiverPort()
    let session = DisplayUSBSession(port: ReceiverPort(), nonce: 77)
    let caps = try session.negotiate()
    #expect(caps.width == 64 && caps.height == 32)
    let first = Data((0..<4096).map { UInt8(($0 / 16) % 256) })
    let link = DisplayUSBSession(port: port, nonce: 17)
    _ = try link.negotiate()
    #expect(try link.send(first))
    #expect(port.pixelCRC == DisplayWire.crc(first))
    #expect(link.planner?.acknowledged == 1)
    let count = port.writes.count
    #expect(try !link.send(first))
    #expect(port.writes.count == count)
    var changed = first
    changed[0] ^= 1
    #expect(try link.send(changed))
    #expect(port.pixelCRC == DisplayWire.crc(changed))
    #expect(port.writes.filter { $0.kind == .begin }.last?.flags == 0)
    // A lost ACK must leave the host baseline unchanged even though the LCD already changed.
    port.state.withLock { $0.dropACK = true }
    changed[4] ^= 1
    #expect(throws: DisplayWire.Failure.self) { try link.send(changed) }
    #expect(link.planner?.acknowledged == 2)
    #expect(link.planner?.baseline != changed)
    #expect(port.pixelCRC == DisplayWire.crc(changed))
    // HELLO with a fresh nonce resets the actual firmware and requires every tile again.
    let reconnected = DisplayUSBSession(port: port, nonce: 18)
    _ = try reconnected.negotiate()
    #expect(try reconnected.send(changed))
    #expect(port.writes.filter { $0.kind == .begin }.last?.flags == 1)
    #expect(reconnected.planner?.acknowledged == 1 && port.pixelCRC == DisplayWire.crc(changed))
    try reconnected.heartbeat()
    port.state.withLock { qeq_test_receiver_expire($0.handle) }
    let recovered = DisplayUSBSession(port: port, nonce: 19)
    _ = try recovered.negotiate()
    #expect(try recovered.send(changed))
}

@Test func settledSceneCanRepaintEveryTileWithoutResettingTheSession() throws {
    let port = ReceiverPort()
    let session = DisplayUSBSession(port: port, nonce: 91)
    let caps = try session.negotiate()
    let pixels = Data(repeating: 73, count: caps.width * caps.height * 2)
    #expect(try session.send(pixels))
    #expect(try !session.send(pixels))
    #expect(try session.send(pixels, forceFull: true))
    #expect(session.planner?.acknowledged == 2)
    #expect(port.writes.filter { $0.kind == .begin }.last?.flags == 1)
    #expect(port.writes.filter { $0.kind == .hello }.count == 1)
    #expect(port.pixelCRC == DisplayWire.crc(pixels))
    #expect(try !session.send(pixels))
}

@Test func nativeTilesUseLosslessLZ4AndRawFallbackAgainstFirmware() throws {
    let port = ReceiverPort()
    let session = DisplayUSBSession(port: ReceiverPort(), nonce: 12)
    _ = try session.negotiate()
    let link = DisplayUSBSession(port: port, nonce: 11)
    _ = try link.negotiate()
    _ = try link.send(Data(repeating: 0x33, count: 4096))
    #expect(port.writes.filter { $0.kind == .tile }.allSatisfy { $0.payload[8] == 1 })
    var generator: UInt32 = 1_234_567
    let noise = Data(
        (0..<4096).map { _ -> UInt8 in
            generator ^= generator << 13
            generator ^= generator >> 17
            generator ^= generator << 5
            return UInt8(truncatingIfNeeded: generator)
        })
    let start = port.writes.count
    _ = try link.send(noise)
    #expect(port.writes.dropFirst(start).filter { $0.kind == .tile }.allSatisfy { $0.payload[8] == 0 })
    #expect(port.pixelCRC == DisplayWire.crc(noise))
}

@Test func reusedHCEncoderProducesIndependentBlocksAfterCapacityFailure() throws {
    let encoder = try #require(qeq_lz4_encoder_create())
    defer { qeq_lz4_encoder_destroy(encoder) }
    for iteration in 0..<24 {
        let size = [512, 1024, 2048][iteration % 3]
        let raw = Data((0..<size).map { UInt8(truncatingIfNeeded: ($0 % 73) * 17 + iteration) })
        var output = Data(count: Int(qeq_lz4_compress_bound(Int32(size))))
        let failed = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                qeq_lz4_encoder_compress(encoder, source.baseAddress, Int32(size), target.baseAddress, 1)
            }
        }
        #expect(failed == 0)
        let count = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                qeq_lz4_encoder_compress(
                    encoder, source.baseAddress, Int32(size), target.baseAddress, Int32(target.count))
            }
        }
        #expect(count > 0 && count < size)
        var decoded = Data(count: size)
        let restored = output.withUnsafeBytes { source in
            decoded.withUnsafeMutableBytes { target in
                qeq_lz4_decompress(source.baseAddress, count, target.baseAddress, Int32(size))
            }
        }
        #expect(restored == size && decoded == raw)
    }
}

@Test func nativeDisplayRejectsCorruptStaleAndOversizedMessages() throws {
    let hello = DisplayWire.Message(kind: .hello, session: 17).encoded()
    #expect(DisplayWire.crc(Data("123456789".utf8)) == 0xCBF4_3926)
    #expect(DisplayWire.crc(Data(), seed: 1234) == 1234)
    for index in [0, 4, 8, 20, 24] {
        var bad = hello
        bad[index] ^= 1
        #expect(throws: DisplayWire.Failure.self) { try DisplayWire.Message(bytes: bad) }
    }
    var decoder = DisplayWire.Decoder()
    #expect(throws: DisplayWire.Failure.self) { try decoder.feed(Data(repeating: 0, count: 9000)) }
    let port = ReceiverPort()
    let session = DisplayUSBSession(port: ReceiverPort(), nonce: 8)
    _ = try session.negotiate()
    let handshake = DisplayUSBSession(port: port, nonce: 7)
    let caps = try handshake.negotiate()
    var planner = DisplayFramePlanner(capabilities: caps, session: 7)
    let preparedValue = try planner.prepare(Data(repeating: 0, count: 4096))
    let prepared = try #require(preparedValue)
    #expect(throws: DisplayWire.Failure.self) { try planner.prepare(prepared.pixels) }
    try port.write(prepared.wire)
    var replyDecoder = DisplayWire.Decoder()
    var replies: [DisplayWire.Message] = []
    while replies.isEmpty { replies += try replyDecoder.feed(port.read(timeout: 1)) }
    var ack = try #require(replies.first)
    ack.session = 8
    #expect(throws: DisplayWire.Failure.self) { try planner.accept(ack) }
    ack.session = 7
    ack.payload[16] = 1  // Correct session/frame but wrong applied tile count.
    #expect(throws: DisplayWire.Failure.self) { try planner.accept(ack) }
    #expect(planner.baseline == nil && planner.acknowledged == 0)
    #expect(HardwareDisplayService.midiSerial("80801427843C-D1") == "80801427843C")
    #expect(HardwareDisplayService.midiSerial("not-a-board") == nil)
}

private final class CountingRenderer: DisplayPixelRenderer, @unchecked Sendable {
    let values = OSAllocatedUnfairLock(initialState: [Int]())
    func pixels(_ content: HardwareDisplayContent) throws -> Data {
        values.withLock { $0.append(content.scene.percent) }
        return Data(repeating: UInt8(content.scene.percent), count: 4096)
    }
}
private func content(_ percent: Int) -> HardwareDisplayContent {
    HardwareDisplayContent(
        scene: HardwareDisplayScene(label: "Music", percent: percent, systemPercent: 50), icon: nil, iconKey: "Music")
}
private func eventually(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test func displayWorkerCoalescesWhileACKPendingAndSleepsWhenUnchanged() async throws {
    let port = ReceiverPort()
    let renderer = CountingRenderer()
    port.state.withLock { $0.holdACK = true }
    let worker = DisplayConnection(
        label: "test", makePort: { port }, makeRenderer: { _ in renderer }, onStatus: { _ in })
    defer { worker.stop() }
    worker.update(content(1))
    worker.start()
    #expect(await eventually { renderer.values.withLock { $0 == [1] } })
    for value in 2...50 { worker.update(content(value)) }
    port.release.signal()
    #expect(await eventually { port.pixelCRC == DisplayWire.crc(Data(repeating: 50, count: 4096)) })
    #expect(renderer.values.withLock { $0 == [1, 50] })
    for _ in 0..<20 { worker.update(content(50)) }
    try await Task.sleep(for: .milliseconds(650))
    #expect(renderer.values.withLock { $0.count == 2 })
    #expect(port.writes.contains { $0.kind == .ping })
    worker.stop()
    #expect(await eventually { port.state.withLock { $0.closed } })
    worker.update(content(99))
    try await Task.sleep(for: .milliseconds(50))
    #expect(renderer.values.withLock { $0.count == 2 })
}

@Test func displayWorkerRecoversLostACKWithFullRefresh() async throws {
    let first = ReceiverPort()
    let second = ReceiverPort()
    let renderer = CountingRenderer()
    first.state.withLock { $0.dropACK = true }
    let attempts = OSAllocatedUnfairLock(initialState: 0)
    let worker = DisplayConnection(
        label: "retry",
        makePort: {
            let attempt = attempts.withLock {
                $0 += 1
                return $0
            }
            return attempt == 1 ? first : second
        }, makeRenderer: { _ in renderer }, onStatus: { _ in })
    defer { worker.stop() }
    worker.update(content(32))
    worker.start()
    #expect(await eventually { second.pixelCRC == DisplayWire.crc(Data(repeating: 32, count: 4096)) })
    #expect(first.state.withLock { $0.closed })
    #expect(second.writes.first?.kind == .hello)
    #expect(second.writes.first { $0.kind == .begin }?.flags == 1)
}

@Test func identicalDisplayPixelsKeepTheUSBSessionAliveDuringSceneUpdates() async throws {
    let port = ReceiverPort()
    let renderer = CountingRenderer()
    let worker = DisplayConnection(
        label: "identical", makePort: { port }, makeRenderer: { _ in renderer }, onStatus: { _ in })
    defer { worker.stop() }
    worker.update(content(50))
    worker.start()
    #expect(await eventually { port.writes.contains { $0.kind == .commit } })
    for step in 1...25 {
        var updated = content(50)
        updated.scene.roundVolumePosition = Double(step) / 25
        worker.update(updated)
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(port.writes.contains { $0.kind == .ping })
    #expect(port.writes.filter { $0.kind == .commit }.count == 1)
}

@Test @MainActor func nativeDisplayDiscoveryLifecycleIsIdempotent() async {
    let service = HardwareDisplayService()
    service.start()
    service.start()
    service.stop()
    service.stop()
    service.start()
    service.stop()
    await Task.yield()
    #expect(service.status.isEmpty)
}
