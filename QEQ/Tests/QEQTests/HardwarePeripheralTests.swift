import Foundation
import QEQCore
import Testing

private func peripheralIdentity() throws -> QEQHardwareIdentity {
    let controls: [UInt8] = [
        1, 0, 16, 2, 1, 17, 3, 2, 18, 4, 2, 19, 5, 0, 20, 6, 2, 21, 7, 0, 22, 8, 2, 23, 9, 0, 24, 10, 2, 25,
    ]
    var bytes = QEQHardwareIdentity.prefix
    bytes += [2, 2, 0, 3, 0, 1, 2, 3, 4]
    bytes += Array("001122AABBCC".utf8)
    bytes += [10] + controls + [0xF7]
    return try #require(QEQHardwareIdentity(message: bytes))
}
@Test func peripheralCapabilitiesValidateOwnershipAndAllowOptionalFeatures() throws {
    let identity = try peripheralIdentity()
    let bytes =
        QEQHardwareIdentity.prefix + [5] + identity.boot + [
            1, 15, 4, 4, 2, 3, 1, 1, 4, 1, 2, 5, 6, 2, 3, 7, 8, 3, 4, 9, 10, 4, 0xF7,
        ]
    let caps = try #require(HardwareCapabilities(message: bytes, identity: identity))
    #expect(caps.pairs.count == 4 && caps.pairs[3].slider == 9 && caps.pairs[3].led == 4)
    #expect(caps.hasLEDs && caps.hasCalibration && caps.hasMediaKeys)
    for index in [7, 11, 13, 14, 15, 16, 17, 18, 19, 20, 22] {
        var corrupt = bytes
        corrupt[index] = 126
        #expect(HardwareCapabilities(message: corrupt, identity: identity) == nil)
    }
    var future = bytes
    future[12] = 127
    #expect(HardwareCapabilities(message: future, identity: identity) != nil)
    var duplicate = bytes
    duplicate[24] = 1
    #expect(HardwareCapabilities(message: duplicate, identity: identity) == nil)
    #expect(HardwareCapabilities(message: Array(bytes.dropLast()), identity: identity) == nil)
}
@Test func calibrationWireRoundTripAndBounds() throws {
    let identity = try peripheralIdentity()
    var config = HardwareCalibration()
    config.minimum = 120
    config.maximum = 3900
    config.reversed = true
    let token: UInt32 = 0x0FFF_FFFF
    let request = try #require(identity.calibration(pair: 4, token: token, setting: config))
    #expect(request.count == 26 && request[15] == 4 && request[16] == 1)
    var reply = Array(request.dropLast())
    reply[6] = 8
    reply[16] = 0
    reply += [127, 31, 0xF7]
    let reading = try #require(HardwareCalibrationReading(message: reply, identity: identity))
    #expect(reading.token == token && reading.raw == 4095 && reading.calibration == config)
    reply[7] ^= 1
    #expect(HardwareCalibrationReading(message: reply, identity: identity) == nil)
    config.maximum = 200
    #expect(identity.calibration(pair: 1, token: 0, setting: config) == nil)
    config = HardwareCalibration()
    config.confirmations = 0
    #expect(!config.valid)
    #expect(identity.calibration(pair: 0, token: 0, setting: nil) == nil)
    #expect(identity.calibration(pair: 1, token: 1 << 28, setting: nil) == nil)
}
@Test func consumerAndLEDAreAddressedBoundedOutputs() throws {
    let identity = try peripheralIdentity()
    let play = try #require(identity.consumerControl(usage: HardwareMediaCommand.playPause.rawValue, token: 1))
    #expect(play == QEQHardwareIdentity.prefix + [4, 1, 2, 3, 4, 1, 0, 0, 0, 77, 1, 0xF7])
    #expect(identity.consumerControl(usage: 0, token: 0) == nil)
    #expect(identity.consumerControl(usage: 1024, token: 0) == nil)
    for id: UInt8 in 1...4 {
        #expect(
            identity.led(id: id, red: 127, green: 10, blue: 0) == QEQHardwareIdentity.prefix + [
                6, 1, 2, 3, 4, id, 127, 10, 0, 0xF7,
            ])
    }
    #expect(identity.led(id: 5, red: 0, green: 0, blue: 0) == nil)
    #expect(identity.led(id: 1, red: 128, green: 0, blue: 0) == nil)
}
@Test func fourPairsKeepIndependentPickupAndButtonState() {
    var states = Array(repeating: HardwareControlState(), count: 4)
    let targets = [0.25, 0.5, 0.75, 1.0]
    for i in 0..<4 {
        #expect(states[i].receive(.control(channel: 15, number: 16, value: 0), targetPosition: targets[i]) == nil)
        #expect(states[i].receive(.control(channel: 15, number: 19, value: 0), targetPosition: targets[i]) == nil)
    }
    #expect(
        states[2].receive(.control(channel: 15, number: 16, value: 100), targetPosition: targets[2])
            == .volume(100.0 / 127))
    #expect(states[2].pickedUp && !states[0].pickedUp && !states[1].pickedUp && !states[3].pickedUp)
    #expect(states[3].receive(.control(channel: 15, number: 19, value: 127), targetPosition: 1) == .toggleMute)
    #expect(states[3].receive(.control(channel: 15, number: 19, value: 127), targetPosition: 1) == nil)
    #expect(states[0].receive(.control(channel: 15, number: 19, value: 127), targetPosition: 0.25) == .toggleMute)
}
