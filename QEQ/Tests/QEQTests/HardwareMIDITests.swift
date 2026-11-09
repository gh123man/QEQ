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
    for index in [5, 7, 15, 27, 29, 40] {
        var corrupt = bytes
        corrupt[index] = 0x7E
        #expect(QEQHardwareIdentity(message: corrupt) == nil)
    }
    #expect(QEQHardwareIdentity(message: Array(bytes.dropLast())) == nil)
    // Four-channel firmware must wait for per-slot host support instead of binding as a prototype.
    #expect(QEQHardwareIdentity(message: try hardwareFixture("identity_four")) == nil)
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
