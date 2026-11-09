import CoreMIDI
import Foundation
import QEQCore
import Testing
import os

@testable import QEQAppSupport

private final class HardwareFixtureBundle {}
private func hardwareFixture(_ name: String) throws -> [UInt8] {
    #if SWIFT_PACKAGE
        let bundle = Bundle.module
    #else
        let bundle = Bundle(for: HardwareFixtureBundle.self)
    #endif
    let url = bundle.url(forResource: "HardwareMIDI", withExtension: "txt")!
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let words = lines.first { $0.hasPrefix(name + " ") }!.split(separator: " ").dropFirst()
    return words.map { UInt8($0, radix: 16)! }
}

@Test func hardwareWireFixturesMatchAndRejectIncompatibleProfiles() throws {
    let bytes = try hardwareFixture("identity")
    let identity = try #require(QEQHardwareIdentity(message: bytes))
    #expect(identity.serial == "001122AABBCC")
    #expect(identity.boot == [1, 2, 3, 4])
    #expect(
        identity.feedback(
            position: 64.0 / 127, percent: 50, available: true,
            muted: false, enabled: true, pickup: true, label: "Music", accent: (32, 64, 96), systemVolume: 0.75)
            == (try hardwareFixture("feedback")))
    for index in [5, 15, 27, 29, 40] {
        var corrupt = bytes
        corrupt[index] = 0x7E
        #expect(QEQHardwareIdentity(message: corrupt) == nil)
    }
    #expect(QEQHardwareIdentity(message: Array(bytes.dropLast())) == nil)
    // Expanded identities are parsed; capabilities determine physical pair assignments.
    #expect(QEQHardwareIdentity(message: try hardwareFixture("identity_four"))?.controls.count == 10)
    #expect(
        identity.feedback(
            position: .nan, percent: 999, available: false,
            muted: false, enabled: false, pickup: false, label: String(repeating: "é", count: 100)
        ).count == 44)
}

@Test func midiDecoderHandlesFragmentationRunningStatusAndRealtime() throws {
    let identity = try hardwareFixture("identity")
    for split in 0...identity.count {
        var decoder = MIDIStreamDecoder()
        let first = decoder.consume(Array(identity.prefix(split)))
        let second = decoder.consume([0xF8] + Array(identity.dropFirst(split)))
        #expect(first + second == [.systemExclusive(identity)])
    }
    var decoder = MIDIStreamDecoder()
    #expect(
        decoder.consume([0xBF, 16, 0xF8, 64, 17, 1, 0xCF, 5, 0xBF, 18, 127]) == [
            .control(channel: 15, number: 16, value: 64),
            .control(channel: 15, number: 17, value: 1),
            .control(channel: 15, number: 18, value: 127),
        ])
    #expect(decoder.consume([0xF0] + Array(repeating: 1, count: 2000) + [0xF7]).isEmpty)
    #expect(decoder.consume([0xF0, 1, 0xBF, 16, 20]) == [.control(channel: 15, number: 16, value: 20)])
}

@Test func hardwarePickupRequiresMotionAcrossTargetAndRearms() {
    var state = HardwareControlState()
    func pot(_ value: UInt8) -> MIDIMessage { .control(channel: 15, number: 16, value: value) }
    #expect(state.receive(pot(100), targetPosition: 0.5) == nil)
    #expect(state.receive(pot(90), targetPosition: 0.5) == nil)
    #expect(state.receive(pot(60), targetPosition: 0.5) == .volume(60.0 / 127))
    #expect(state.receive(pot(59), targetPosition: 0.5) == .volume(59.0 / 127))
    state.rearm()
    #expect(state.receive(pot(59), targetPosition: 0.8) == nil)
    #expect(state.receive(pot(80), targetPosition: 0.8) == nil)
    #expect(state.receive(pot(110), targetPosition: 0.8) == .volume(110.0 / 127))
    state.rearm()
    #expect(state.receive(pot(127), targetPosition: 1) == nil)
    #expect(state.receive(pot(127), targetPosition: 1) == nil)
    #expect(state.receive(pot(125), targetPosition: 1) == .volume(125.0 / 127))
}

@Test func hardwarePickupRetainsKnownSliderPositionWhenAnAppBecomesAvailable() {
    var state = HardwareControlState()
    func pot(_ value: UInt8) -> MIDIMessage { .control(channel: 15, number: 16, value: value) }
    state.rearm(sliderPosition: 54)
    #expect(state.receive(pot(54), targetPosition: 0.43) == nil)
    // A 43% saved volume is crossed by the first upward move from the 54 baseline.
    #expect(state.receive(pot(57), targetPosition: 0.43) == .volume(57.0 / 127))
    state.rearm(sliderPosition: 54)
    #expect(state.receive(pot(52), targetPosition: 0.42) == .volume(52.0 / 127))
    // A newly assigned app far from the physical slider still requires pickup.
    state.rearm(sliderPosition: 54)
    #expect(state.receive(pot(57), targetPosition: 0.8) == nil)
    #expect(state.receive(pot(110), targetPosition: 0.8) == .volume(110.0 / 127))
}

@Test func hardwareButtonsIgnoreBootHoldReleaseAndDuplicatePresses() {
    var state = HardwareControlState()
    func button(_ value: UInt8) -> MIDIMessage { .control(channel: 15, number: 19, value: value) }
    #expect(state.receive(button(127), targetPosition: 1) == nil)
    #expect(state.receive(button(0), targetPosition: 1) == nil)
    #expect(state.receive(button(127), targetPosition: 1) == .toggleMute)
    #expect(state.receive(button(127), targetPosition: 1) == nil)
    #expect(state.receive(.control(channel: 15, number: 17, value: 127), targetPosition: 1) == .systemVolume(-1))
    #expect(state.receive(.control(channel: 15, number: 17, value: 64), targetPosition: 1) == nil)
    #expect(state.receive(.control(channel: 15, number: 18, value: 127), targetPosition: 1) == nil)
    #expect(state.receive(.control(channel: 15, number: 18, value: 0), targetPosition: 1) == nil)
    #expect(state.receive(.control(channel: 15, number: 18, value: 127), targetPosition: 1) == .toggleGlobalBypass)
    #expect(state.receive(.control(channel: 15, number: 18, value: 127), targetPosition: 1) == nil)
    #expect(state.receive(.control(channel: 0, number: 18, value: 127), targetPosition: 1) == nil)
}

@Test @MainActor func midiServiceRequiresIdentityAndRoundTripsThroughCoreMIDI() async throws {
    var client: MIDIClientRef = 0
    try #require(MIDIClientCreate("QEQ MIDI test" as CFString, nil, nil, &client) == noErr)
    defer { MIDIClientDispose(client) }
    var source: MIDIEndpointRef = 0
    var destination: MIDIEndpointRef = 0
    let received = OSAllocatedUnfairLock(initialState: [UInt8]())
    try #require(MIDISourceCreate(client, "QEQ test source" as CFString, &source) == noErr)
    try #require(
        MIDIDestinationCreateWithBlock(client, "QEQ test feedback" as CFString, &destination) { @Sendable list, _ in
            let (bytes, overflow) = HardwareMIDIService.copyPacketBytes(list)
            if !overflow { received.withLock { $0.append(contentsOf: bytes) } }
        } == noErr)
    let input = source
    let output = destination
    // A long heartbeat proves state changes use the fast path rather than timer polling.
    let service = HardwareMIDIService(candidates: { [(input, output)] }, heartbeatInterval: 60)
    defer { service.stop() }
    var events: [MIDIMessage] = []
    service.onMessage = { _, message in events.append(message) }
    let feedback = try hardwareFixture("feedback")
    service.feedback = { _ in feedback }
    service.start()
    func emit(_ bytes: [UInt8]) {
        var list = MIDIPacketList()
        bytes.withUnsafeBufferPointer { buffer in
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIPacketListInit(pointer)
                MIDIPacketListAdd(
                    pointer, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, buffer.baseAddress!)
                #expect(MIDIReceived(input, pointer) == noErr)
            }
        }
    }
    emit([0xBF, 16, 20])
    try await Task.sleep(for: .milliseconds(80))
    #expect(events.isEmpty)
    let identity = try hardwareFixture("identity")
    emit(Array(identity.prefix(13)))
    emit(Array(identity.dropFirst(13)))
    emit([0xBF, 16, 30])
    for _ in 0..<30 {
        if !received.withLock({ $0.isEmpty }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(service.devices.count == 1)
    #expect(events == [.control(channel: 15, number: 16, value: 30)])
    #expect(received.withLock { Array($0.prefix(feedback.count)) } == feedback)
    var changed = feedback
    changed[13] = 25
    service.feedback = { _ in changed }
    for _ in 0..<100 { service.requestFeedback() }
    for _ in 0..<20 {
        if received.withLock({ $0.count }) >= feedback.count * 2 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(received.withLock { $0 } == feedback + changed)
    // Repeated requests for identical state must not flood the USB device.
    service.requestFeedback()
    try await Task.sleep(for: .milliseconds(50))
    #expect(received.withLock { $0.count } == feedback.count * 2)
    service.reconnect()
    #expect(service.devices.isEmpty)
    emit([0xBF, 18, 127])
    try await Task.sleep(for: .milliseconds(80))
    #expect(events.count == 1)
    emit(identity)
    try await Task.sleep(for: .milliseconds(80))
    #expect(service.devices.count == 1)
}

@Test func sliderNoiseThresholdAccumulatesTravelFromLastAcceptedPosition() {
    var motion = HardwareSliderMotion()
    let initial = motion.accept(64)
    #expect(initial)
    for value: UInt8 in [63, 64, 65, 64, 65] {
        let accepted = motion.accept(value)
        #expect(!accepted)
    }
    #expect(motion.lastAccepted == 64)
    let upward = motion.accept(66)
    let jitter = motion.accept(65)
    let downward = motion.accept(64)
    let invalid = motion.accept(255)
    #expect(upward)
    #expect(!jitter)
    #expect(downward)
    #expect(!invalid)
    #expect(motion.lastAccepted == 64)
}

@Test func sliderAlwaysAcceptsTheFinalStepToEitherEndpoint() {
    var motion = HardwareSliderMotion()
    let readings: [(UInt8, Bool)] = [
        (124, true), (126, true), (127, true), (127, false), (126, false),
        (3, true), (1, true), (0, true), (0, false), (1, false),
    ]
    for (value, expected) in readings {
        let accepted = motion.accept(value)
        #expect(accepted == expected)
        if accepted { #expect(motion.lastAccepted == value) }
    }
    #expect(motion.lastAccepted == 0)
}

@Test @MainActor func peripheralServiceRequiresCapabilitiesAndConfirmsCommands() async throws {
    var client: MIDIClientRef = 0
    try #require(MIDIClientCreate("QEQ peripheral test" as CFString, nil, nil, &client) == noErr)
    defer { MIDIClientDispose(client) }
    var source: MIDIEndpointRef = 0
    var destination: MIDIEndpointRef = 0
    let received = OSAllocatedUnfairLock(initialState: [UInt8]())
    try #require(MIDISourceCreate(client, "QEQ peripheral input" as CFString, &source) == noErr)
    try #require(
        MIDIDestinationCreateWithBlock(client, "QEQ peripheral output" as CFString, &destination) { @Sendable list, _ in
            let (bytes, overflow) = HardwareMIDIService.copyPacketBytes(list)
            if !overflow { received.withLock { $0 += bytes } }
        } == noErr)
    let input = source
    let output = destination
    let service = HardwareMIDIService(candidates: { [(input, output)] }, heartbeatInterval: 60)
    defer { service.stop() }
    func emit(_ bytes: [UInt8]) {
        var list = MIDIPacketList()
        bytes.withUnsafeBufferPointer { buffer in
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIPacketListInit(pointer)
                MIDIPacketListAdd(
                    pointer, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, buffer.baseAddress!)
                #expect(MIDIReceived(input, pointer) == noErr)
            }
        }
    }
    func messages() -> [[UInt8]] {
        var decoder = MIDIStreamDecoder()
        return decoder.consume(received.withLock { $0 }).compactMap {
            if case .systemExclusive(let bytes) = $0 { return bytes }
            return nil
        }
    }
    service.start()
    var identityBytes = try hardwareFixture("identity_four")
    identityBytes.replaceSubrange(15..<27, with: Array("ABCDEF012345".utf8))
    let identity = try #require(QEQHardwareIdentity(message: identityBytes))
    emit(identityBytes)
    try await Task.sleep(for: .milliseconds(80))
    var beforeCapabilities: Bool?
    service.sendMedia(.playPause, source: source) { beforeCapabilities = $0 }
    #expect(beforeCapabilities == false)
    let caps =
        QEQHardwareIdentity.prefix + [5] + identity.boot + [
            1, 15, 4, 4, 2, 3, 1, 1, 4, 1, 2, 5, 6, 2, 3, 7, 8, 3, 4, 9, 10, 4, 0xF7,
        ]
    emit(caps)
    try await Task.sleep(for: .milliseconds(80))
    #expect(service.devices.first?.capabilities?.pairs.count == 4)
    var accepted: Bool?
    service.sendMedia(.playPause, source: source) { accepted = $0 }
    try await Task.sleep(for: .milliseconds(80))
    let request = try #require(messages().last(where: { $0[6] == 4 }))
    #expect(accepted == nil && request[15] == 77 && request[16] == 1)
    var ack = Array(request.prefix(15)) + [4, 0, 0xF7]
    ack[6] = 9
    var stale = ack
    stale[7] ^= 1
    emit(stale)
    try await Task.sleep(for: .milliseconds(50))
    #expect(accepted == nil)
    emit(ack)
    try await Task.sleep(for: .milliseconds(50))
    #expect(accepted == true)
    var reading: HardwareCalibrationReading?
    service.calibrate(source: source, pair: 4) { reading = $0 }
    try await Task.sleep(for: .milliseconds(50))
    var response = Array(try #require(messages().last(where: { $0[6] == 7 })).dropLast())
    response[6] = 8
    response[16] = 0
    response += [100, 10, 0xF7]
    var wrongPair = response
    wrongPair[15] = 3
    emit(wrongPair)
    try await Task.sleep(for: .milliseconds(50))
    #expect(reading == nil)
    emit(response)
    try await Task.sleep(for: .milliseconds(50))
    #expect(reading?.pair == 4 && reading?.raw == 1380)
    var cancelled: Bool?
    service.sendMedia(.next, source: source) { cancelled = $0 }
    service.stop()
    #expect(cancelled == false)
}
