import Foundation

public enum EQPreset: String, CaseIterable, Identifiable, Sendable {
    case flat = "Flat EQ"
    case cutBass = "Cut bass"
    case boostBass = "Bass boost"
    case voice = "Voice clarity"
    case warm = "Warm"
    case bright = "Bright"
    case soften = "Soften harshness"
    case scoop = "Scooped mids"
    case loudness = "Loudness"
    case rumble = "Remove rumble"
    case telephone = "Telephone"

    public var id: String { rawValue }
    /// Presets affect EQ only; volume, mute, and bypass are kept as set by the user.
    public var bands: [EQBand] {
        var bands = MixerSettings.defaultBands
        switch self {
        case .flat: break
        case .cutBass: bands[0].gain = -12
        case .boostBass:
            bands[0] = EQBand(type: .lowShelf, frequency: 120, gain: 5, q: 1)
        case .voice:
            bands[0] = EQBand(type: .highPass, frequency: 100)
            bands[3].gain = 3
        case .warm:
            bands[0].gain = 3
            bands[4].gain = -2
        case .bright:
            bands[0].gain = -2
            bands[4].gain = 4
        case .soften:
            bands[3] = EQBand(frequency: 3500, gain: -4, q: 1.2)
            bands[4].gain = -2
        case .scoop:
            bands[2] = EQBand(frequency: 800, gain: -4, q: 0.8)
        case .loudness:
            bands[0] = EQBand(type: .lowShelf, frequency: 120, gain: 4, q: 1)
            bands[4].gain = 3
        case .rumble:
            bands[0] = EQBand(type: .highPass, frequency: 60)
        case .telephone:
            bands[0] = EQBand(type: .highPass, frequency: 300)
            bands[4] = EQBand(type: .lowPass, frequency: 3400)
        }
        return bands
    }
}
