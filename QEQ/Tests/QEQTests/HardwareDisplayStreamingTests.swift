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

@Test func roundDisplaySlidesFromVisibleFrameAndHonorsReduceMotion() throws {
    let renderer = try RoundDisplayRenderer(HardwareDisplayCapabilities())
    var home = content(50)
    home.scene.roundShowsSystemVolume = true
    home.scene.roundScreen = .home(Array(repeating: 140, count: 48))
    let initial = renderer.render(home, now: 1)
    #expect(initial.count == 240 * 240 * 2 && initial.prefix(2) == Data([0, 0]))
    #expect(!renderer.animating)

    var menu = home
    menu.scene.roundScreen = .menu(
        items: [
            .init("Music controls", iconKey: "music"), .init("Music", iconKey: "app"), .init("Home", iconKey: "home"),
        ], selected: 0)
    #expect(renderer.render(menu, now: 2) == initial)
    let middle = renderer.render(menu, now: 2.13)
    #expect(renderer.animating && middle != initial)

    var slider = home
    slider.scene.roundScreen = .app(slider: true)
    #expect(renderer.render(slider, now: 2.14) == middle)
    let final = renderer.render(slider, now: 2.5)
    #expect(!renderer.animating && final != middle)
    slider.scene.percent = 10
    slider.scene.roundVolumePosition = 0.5
    #expect(renderer.render(slider, now: 3) == final)
    #expect(renderer.animating)
    var halfway = slider
    halfway.scene.percent = 30
    halfway.scene.roundVolumePosition = 0.75
    let reference = try RoundDisplayRenderer(HardwareDisplayCapabilities())
    #expect(renderer.render(slider, now: 3.09) == reference.render(halfway, now: 3.09))
    #expect(renderer.render(slider, now: 3.2) != final)
    #expect(!renderer.animating)

    home.scene.reduceMotion = true
    #expect(renderer.render(home, now: 4) == initial)
    #expect(!renderer.animating)
}

@Test func roundVolumeKeepsMovingWhenKnobUpdatesRetargetTheAnimation() throws {
    let caps = HardwareDisplayCapabilities()
    let renderer = try RoundDisplayRenderer(caps)
    var home = content(50)
    home.scene.roundShowsSystemVolume = true
    home.scene.roundScreen = .home([])
    home.scene.systemPercent = 20
    let start = renderer.render(home, now: 1)
    home.scene.systemPercent = 60
    #expect(renderer.render(home, now: 2) == start)
    home.scene.systemPercent = 80
    let reference = try RoundDisplayRenderer(caps)
    var halfway = home
    halfway.scene.systemPercent = 40
    #expect(renderer.render(home, now: 2.09) == reference.render(halfway, now: 2.09))
    let settled = renderer.render(home, now: 2.28)
    home.scene.reduceMotion = true
    #expect(settled == reference.render(home, now: 2.28))
    #expect(!renderer.animating)
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

@Test func metalRendererCachesUnchangedLayersAndNegotiatesOutput() throws {
    guard ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0" else { return }
    let caps = HardwareDisplayCapabilities()
    let renderer = try MetalHardwareDisplayRenderer(capabilities: caps)
    var scene = HardwareDisplayScene(label: "Music", percent: 10, systemPercent: 40)
    let first = try renderer.render(scene)
    #expect(first.count == 240 * 240 * 2 && first[0] == 0 && first[1] == 0)
    #expect(renderer.rasterizedLayers == 7)
    #expect(try renderer.render(scene) == first)
    #expect(renderer.rasterizedLayers == 7)
    scene.percent = 11
    #expect(try renderer.render(scene) != first)
    #expect(renderer.rasterizedLayers == 8)
    let landscape = try MetalHardwareDisplayRenderer(
        capabilities: HardwareDisplayCapabilities(width: 320, height: 180, orientation: 1, shape: 0))
    #expect(try landscape.render(scene).count == 320 * 180 * 2)
}

@Test func carouselRetargetsFromVisibleIconsAndSettlesWithoutQueuedSteps() throws {
    let caps = HardwareDisplayCapabilities()
    let renderer = try RoundDisplayRenderer(caps)
    var scene = content(50)
    let items: [HardwareRoundScreen.Item] = [
        .init("Music controls", iconKey: "music"), .init("Spotify", iconKey: "spotify"),
        .init("Home", iconKey: "home"),
    ]
    scene.scene.roundScreen = .menu(items: items, selected: 0)
    let initial = renderer.render(scene, now: 1)
    // Ignore labels/dots: the carousel's icons should start exactly where the last
    // delivered frame left them, including when the user reverses direction.
    func icons(_ pixels: Data) -> Data { pixels.subdata(in: (60 * 240 * 2)..<(160 * 240 * 2)) }
    scene.scene.roundScreen = .menu(items: items, selected: 2)
    #expect(icons(renderer.render(scene, now: 2)) == icons(initial))
    let middle = renderer.render(scene, now: 2.1)
    #expect(renderer.animating && icons(middle) != icons(initial))
    scene.scene.roundScreen = .menu(items: items, selected: 0)
    #expect(icons(renderer.render(scene, now: 2.11)) == icons(middle))
    #expect(renderer.render(scene, now: 2.5) == initial)
    #expect(!renderer.animating)
    scene.scene.reduceMotion = true
    scene.scene.roundScreen = .menu(items: items, selected: 1)
    _ = renderer.render(scene, now: 3)
    #expect(!renderer.animating)
}

@Test func homeVolumeOverlayFadesAwayAndIdleSpectrumIgnoresVolume() throws {
    let renderer = try RoundDisplayRenderer(HardwareDisplayCapabilities())
    var home = content(50)
    home.scene.roundScreen = .home([0, 60, 180, 90, 220, 30])
    home.scene.systemPercent = 20
    let idle = renderer.render(home, now: 1)
    home.scene.systemPercent = 80
    #expect(renderer.render(home, now: 2) == idle)
    #expect(renderer.render(home, now: 2.3) == idle)
    home.scene.roundShowsSystemVolume = true
    #expect(renderer.render(home, now: 3) == idle)
    let visible = renderer.render(home, now: 3.2)
    #expect(visible != idle)
    home.scene.roundShowsSystemVolume = false
    #expect(renderer.render(home, now: 4) == visible)
    #expect(renderer.animating)
    #expect(renderer.render(home, now: 4.2) == idle)
    #expect(!renderer.animating)
    home.scene.reduceMotion = true
    home.scene.roundShowsSystemVolume = true
    #expect(renderer.render(home, now: 5) == visible)
    #expect(!renderer.animating)
    home.scene.roundShowsSystemVolume = false
    #expect(renderer.render(home, now: 6) == idle)
}
