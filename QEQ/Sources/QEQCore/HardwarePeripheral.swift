import Foundation

public struct HardwareCapabilities: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public let id: UInt8
        public let slider: UInt8
        public let button: UInt8
        public let led: UInt8
    }
    public let features: UInt8
    public let encoder: UInt8
    public let encoderButton: UInt8
    public let ledCount: UInt8
    public let pairs: [Pair]
    public var hasLEDs: Bool { features & 1 != 0 }
    public var hasCalibration: Bool { features & 2 != 0 }
    public var hasMediaKeys: Bool { features & 4 != 0 }
    public init?(message b: [UInt8], identity: QEQHardwareIdentity) {
        guard identity.matches(b, kind: 5), b.count >= 18, b[11] == 1,
            b[13] > 0, b[13] <= 4, b[14] <= 4, b.count == 18 + Int(b[13]) * 4,
            identity.controls.contains(where: { $0.id == b[15] && $0.kind == 1 }),
            identity.controls.contains(where: { $0.id == b[16] && $0.kind == 2 })
        else { return nil }
        var pairs: [Pair] = []
        for i in stride(from: 17, to: b.count - 1, by: 4) {
            let pair = Pair(id: b[i], slider: b[i + 1], button: b[i + 2], led: b[i + 3])
            guard pair.id == UInt8(pairs.count + 1), pair.led <= b[14], pair.button != b[16],
                identity.controls.contains(where: { $0.id == pair.slider && $0.kind == 0 }),
                identity.controls.contains(where: { $0.id == pair.button && $0.kind == 2 }),
                !pairs.contains(where: {
                    $0.slider == pair.slider || $0.button == pair.button || ($0.led == pair.led && pair.led != 0)
                })
            else { return nil }
            pairs.append(pair)
        }
        encoder = b[15]
        encoderButton = b[16]
        features = b[12]
        ledCount = b[14]
        self.pairs = pairs
    }
}
public enum HardwareMediaCommand: UInt16, Sendable {
    case previous = 0xB6
    case playPause = 0xCD
    case next = 0xB5
}
public struct HardwareCalibration: Equatable, Codable, Sendable {
    public var minimum: Int = 0
    public var maximum: Int = 4095
    public var reversed = false
    public var threshold = 2
    public var confirmations = 3
    public var smoothing = 2
    public init() {}
    public var valid: Bool {
        (0...2047).contains(minimum) && maximum <= 4095 && maximum >= minimum + 1024
            && (1...8).contains(threshold) && (1...10).contains(confirmations) && (1...4).contains(smoothing)
    }
    var bytes: [UInt8] {
        [
            UInt8(minimum & 127), UInt8(minimum >> 7), UInt8(maximum & 127), UInt8(maximum >> 7),
            reversed ? 1 : 0, UInt8(threshold), UInt8(confirmations), UInt8(smoothing),
        ]
    }
}
public struct HardwareCalibrationReading: Equatable, Sendable {
    public let token: UInt32
    public let pair: UInt8
    public let calibration: HardwareCalibration
    public let raw: Int
    public init?(message b: [UInt8], identity: QEQHardwareIdentity) {
        guard b.count == 28, identity.matches(b, kind: 8), (1...4).contains(b[15]), b[16] == 0, b[21] <= 1 else {
            return nil
        }
        var c = HardwareCalibration()
        c.minimum = Int(b[17]) | Int(b[18]) << 7
        c.maximum = Int(b[19]) | Int(b[20]) << 7
        c.reversed = b[21] != 0
        c.threshold = Int(b[22])
        c.confirmations = Int(b[23])
        c.smoothing = Int(b[24])
        raw = Int(b[25]) | Int(b[26]) << 7
        guard c.valid, raw <= 4095 else { return nil }
        token = Self.token(b)
        pair = b[15]
        calibration = c
    }
    public static func token(_ b: [UInt8]) -> UInt32 {
        UInt32(b[11]) | UInt32(b[12]) << 7 | UInt32(b[13]) << 14 | UInt32(b[14]) << 21
    }
}
extension QEQHardwareIdentity {
    public func matches(_ b: [UInt8], kind: UInt8) -> Bool {
        b.count >= 12 && b.count <= 64 && Array(b.prefix(7)) == Self.prefix + [kind]
            && Array(b[7..<11]) == boot && b.last == 0xF7 && b[7..<(b.count - 1)].allSatisfy { $0 < 128 }
    }
    private func request(_ kind: UInt8, token: UInt32) -> [UInt8] {
        var bytes = Self.prefix + [kind] + boot
        for shift in [0, 7, 14, 21] { bytes.append(UInt8((token >> shift) & 127)) }
        return bytes
    }
    public func consumerControl(usage: UInt16, token: UInt32) -> [UInt8]? {
        guard usage > 0, usage <= 0x3FF, token < (1 << 28) else { return nil }
        return request(4, token: token) + [UInt8(usage & 127), UInt8(usage >> 7), 0xF7]
    }
    public func led(id: UInt8, red: UInt8, green: UInt8, blue: UInt8) -> [UInt8]? {
        guard (1...4).contains(id), red < 128, green < 128, blue < 128 else { return nil }
        return Self.prefix + [6] + boot + [id, red, green, blue, 0xF7]
    }
    public func calibration(pair: UInt8, token: UInt32, setting: HardwareCalibration?) -> [UInt8]? {
        let calibration = setting ?? HardwareCalibration()
        guard (1...4).contains(pair), token < (1 << 28), calibration.valid else { return nil }
        return request(7, token: token) + [pair, setting == nil ? 0 : 1] + calibration.bytes + [0xF7]
    }
}
