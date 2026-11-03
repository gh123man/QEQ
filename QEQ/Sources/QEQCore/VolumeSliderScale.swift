import Foundation

/// Slider travel is independent of stored linear gain and the meter's dBFS scale.
public struct VolumeSliderScale {
    public static let boostedUnityPosition = 0.8
    public let maximum: Double

    public init(maximum: Double) {
        self.maximum = maximum.isFinite ? max(1, min(MixerSettings.boostedVolumeLimit, maximum)) : 1
    }

    public var unityPosition: Double { maximum > 1 ? Self.boostedUnityPosition : 1 }

    public func gain(at position: Double) -> Double {
        let position = position.isFinite ? max(0, min(1, position)) : 0
        if position <= unityPosition { return position / unityPosition }
        // Equal travel in the boost region gives equal dB steps: 100%, ~141%, 200%.
        return pow(maximum, (position - unityPosition) / (1 - unityPosition))
    }

    public func position(for gain: Double) -> Double {
        let gain = gain.isFinite ? max(0, min(maximum, gain)) : 1
        if gain <= 1 { return gain * unityPosition }
        return unityPosition + (1 - unityPosition) * log(gain) / log(maximum)
    }
}
