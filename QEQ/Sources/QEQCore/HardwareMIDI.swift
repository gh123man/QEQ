import Foundation

public enum MIDIMessage: Equatable, Sendable {
    case control(channel: UInt8, number: UInt8, value: UInt8)
    case systemExclusive([UInt8])
}

/// Bounded MIDI 1 byte-stream decoder. Packet boundaries are not message boundaries.
public struct MIDIStreamDecoder: Sendable {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var sysex: [UInt8]? = nil
    public init() {}
    public mutating func consume(_ bytes: [UInt8]) -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }  // Realtime bytes may interrupt any message.
            if byte == 0xF0 {
                sysex = [byte]
                status = 0
                data = []
                continue
            }
            if byte == 0xF7 {
                if var message = sysex {
                    message.append(byte)
                    result.append(.systemExclusive(message))
                }
                sysex = nil
                status = 0
                data = []
                continue
            }
            if byte & 0x80 != 0 {
                sysex = nil
                data = []
                status = byte < 0xF0 ? byte : 0
                continue
            }
            if sysex != nil {
                if sysex!.count < 63 { sysex!.append(byte) } else { sysex = nil }
                continue
            }
            guard status != 0 else { continue }
            data.append(byte)
            let length = status & 0xE0 == 0xC0 ? 1 : 2
            if data.count == length {
                if status & 0xF0 == 0xB0 {
                    result.append(.control(channel: status & 0x0F, number: data[0], value: data[1]))
                }
                data = []
            }
        }
        return result
    }
}

public struct QEQHardwareIdentity: Equatable, Sendable {
    public let serial: String
    public let boot: [UInt8]
    public let firmware: [UInt8]
    public static let prefix: [UInt8] = [0xF0, 0x7D, 0x51, 0x45, 0x51, 2]
    // Logical ID, kind (absolute / relative / button), controller number.
    public static let testBoardControls: [UInt8] = [1, 0, 16, 2, 1, 17, 3, 2, 18, 4, 2, 19]
    public struct Control: Equatable, Sendable {
        public let id: UInt8
        public let kind: UInt8
        public let controller: UInt8
    }
    public let model: UInt8
    public let controls: [Control]
    public init?(message: [UInt8]) {
        guard message.count >= 32, message.count <= 64,
            Array(message.prefix(7)) == Self.prefix + [2], message.last == 0xF7,
            message[7] > 0, message[8..<(message.count - 1)].allSatisfy({ $0 < 128 }),
            message[27] > 0, message.count == 29 + Int(message[27]) * 3,
            message[15..<27].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) })
        else { return nil }
        var decoded: [Control] = []
        for offset in stride(from: 28, to: message.count - 1, by: 3) {
            let control = Control(id: message[offset], kind: message[offset + 1], controller: message[offset + 2])
            guard control.id > 0, control.kind <= 2,
                !decoded.contains(where: { $0.id == control.id || $0.controller == control.controller })
            else { return nil }
            decoded.append(control)
        }
        model = message[7]
        controls = decoded
        firmware = Array(message[8..<11])
        boot = Array(message[11..<15])
        serial = String(decoding: message[15..<27], as: UTF8.self)
    }
    public func feedback(
        position: Double, percent: Int, available: Bool, muted: Bool,
        enabled: Bool, pickup: Bool, label: String,
        accent: (UInt8, UInt8, UInt8) = (0, 0, 0), systemVolume: Double? = nil
    ) -> [UInt8] {
        let flags: UInt8 = (available ? 1 : 0) | (muted ? 2 : 0) | (enabled ? 4 : 0) | (pickup ? 8 : 0)
        let value = UInt8((min(1, max(0, position.isFinite ? position : 0)) * 127).rounded())
        let percent = min(200, max(0, percent))
        let text = label.unicodeScalars.prefix(24).map { UInt8($0.value >= 32 && $0.value < 127 ? $0.value : 63) }
        var message = Self.prefix
        message.append(3)
        message.append(contentsOf: boot)
        message.append(contentsOf: [flags, value, UInt8(percent & 127), UInt8(percent >> 7)])
        message.append(contentsOf: [min(127, accent.0), min(127, accent.1), min(127, accent.2)])
        let systemPercent = systemVolume.flatMap { $0.isFinite ? UInt8((min(1, max(0, $0)) * 100).rounded()) : nil }
        message.append(systemPercent ?? 127)
        message.append(contentsOf: text)
        message.append(0xF7)
        return message
    }
}

public enum HardwareAction: Equatable, Sendable {
    case volume(Double)
    case systemVolume(Int)
    case toggleMute
    case toggleGlobalBypass
}

/// Compare with the last accepted position so slow travel accumulates while
/// sub-percent chatter neither changes volume nor retriggers the display.
public struct HardwareSliderMotion: Sendable {
    public private(set) var lastAccepted: UInt8?
    public init() {}
    public mutating func accept(_ value: UInt8) -> Bool {
        guard value <= 127 else { return false }
        if let lastAccepted {
            if value == lastAccepted { return false }
            // Always finish at the rails, even when the final MIDI step is <1%.
            if value != 0, value != 127, abs(Int(value) - Int(lastAccepted)) * 100 < 127 { return false }
        }
        lastAccepted = value
        return true
    }
}

/// Per-device state; a fresh session, target, or UI volume edit rearms pickup.
public struct HardwareControlState: Sendable {
    public private(set) var pickedUp = false
    private var previous: Double?
    private var buttons: [UInt8: Bool] = [:]
    public init() {}
    public mutating func rearm(sliderPosition: UInt8? = nil) {
        pickedUp = false
        // Reuse the physical baseline when an app appears or its target changes.
        // The motion gate suppresses duplicate snapshots, so they cannot restore
        // a discarded baseline before the user's first deliberate movement.
        previous = sliderPosition.flatMap { $0 <= 127 ? Double($0) / 127 : nil }
    }
    public mutating func receive(_ message: MIDIMessage, targetPosition: Double) -> HardwareAction? {
        guard case .control(let channel, let number, let value) = message, channel == 15 else { return nil }
        switch number {
        case 16:
            let position = Double(value) / 127
            defer { previous = position }
            // First observation is a baseline, never an instruction to change volume.
            guard let previous else { return nil }
            if abs(position - previous) < 0.0001 { return nil }
            if !pickedUp {
                pickedUp =
                    abs(position - targetPosition) <= 0.5 / 127
                    || (min(previous, position)...max(previous, position)).contains(targetPosition)
            }
            return pickedUp ? .volume(position) : nil
        case 17:
            guard value != 0, value != 64 else { return nil }
            return .systemVolume(value < 64 ? Int(value) : Int(value) - 128)
        case 18, 19:
            let down = value >= 64
            let wasDown = buttons.updateValue(down, forKey: number)
            guard wasDown == false, down else { return nil }
            return number == 18 ? .toggleGlobalBypass : .toggleMute
        default: return nil
        }
    }
}
