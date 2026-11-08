import CoreAudio
import Foundation

/// Controls the current macOS output, independently of QEQ's processing routes.
@MainActor
public final class SystemOutputVolume {
    public private(set) var error: String?
    public init() {}

    public func value() -> Double? {
        guard let controls = try? readControls() else { return nil }
        return controls.values.max().map(Double.init)
    }

    public func adjust(steps: Int) {
        guard steps != 0 else { return }
        do {
            let controls = try readControls()
            let values = Self.adjusted(controls.values, steps: steps)
            for (element, scalar) in zip(controls.elements, values) {
                var address = Self.address(element)
                var value = scalar
                try checkAudio(AudioObjectSetPropertyData(controls.device, &address, 0, nil,
                    UInt32(MemoryLayout<Float32>.size), &value), "Set system volume")
            }
            error = nil
        } catch {
            let message = "System volume unavailable: \(error.localizedDescription)"
            if self.error != message { AppLog.shared.write(.warning, message) }
            self.error = message
        }
    }

    // One electrical encoder step changes volume by 1/64. Preserve channel balance.
    static func adjusted(_ values: [Float32], steps: Int) -> [Float32] {
        guard let peak = values.max(), peak.isFinite, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else { return values }
        let next = min(1, max(0, Double(peak) + Double(steps) / 64))
        return values.map { peak == 0 ? Float32(next) : Float32(Double($0 / peak) * next) }
    }

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func readControls() throws -> (device: AudioDeviceID, elements: [UInt32], values: [Float32]) {
        let device = try HAL.uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard device != 0 else { throw AudioFailure(message: "No system output") }
        func writable(_ element: UInt32) -> Bool {
            var address = Self.address(element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &address)
                && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
        let elements: [UInt32]
        if writable(kAudioObjectPropertyElementMain) {
            elements = [kAudioObjectPropertyElementMain]
        } else {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var channels: [UInt32] = [1, 2]
            var size = UInt32(2 * MemoryLayout<UInt32>.size)
            let result = channels.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
            }
            guard result == noErr, size == 8, channels.allSatisfy({ $0 > 0 && writable($0) }) else {
                throw AudioFailure(message: "This output has no writable volume control")
            }
            elements = Array(Set(channels)).sorted()
        }
        let values = try elements.map { element -> Float32 in
            var address = Self.address(element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            try checkAudio(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value), "Read system volume")
            guard value.isFinite, (0...1).contains(value) else { throw AudioFailure(message: "Invalid output volume") }
            return value
        }
        return (device, elements, values)
    }
}
