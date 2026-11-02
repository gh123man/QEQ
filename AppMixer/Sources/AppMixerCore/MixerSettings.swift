import Foundation
import MixerDSP

public enum EQFilter: UInt32, Codable, CaseIterable, Sendable {
    case lowShelf = 0
    case bell = 1
    case highShelf = 2
    case highPass = 3
    case lowPass = 4
    public var label: String {
        switch self {
        case .lowShelf: "Low shelf"
        case .bell: "Bell"
        case .highShelf: "High shelf"
        case .highPass: "Low cut"
        case .lowPass: "High cut"
        }
    }
    public var isShelf: Bool { self == .lowShelf || self == .highShelf }
    public var hasGain: Bool { self != .highPass && self != .lowPass }
}
public struct EQBand: Codable, Equatable, Sendable {
    public var type: EQFilter
    public var frequency: Double
    public var gain: Double
    /// Q for bells/cuts; shelf slope S (0.1...1) for shelves.
    public var q: Double
    public var enabled: Bool
    public init(
        type: EQFilter = .bell, frequency: Double, gain: Double = 0, q: Double = 0.70710678, enabled: Bool = true
    ) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.enabled = enabled
    }
    public var isFlat: Bool { !enabled || (type.hasGain && gain == 0) }
    public func sanitized() -> Self {
        var b = self
        b.frequency = bounded(frequency, 20, 20000, fallback: 1000)
        b.gain = bounded(gain, -18, 18)
        b.q = bounded(q, 0.1, type.isShelf ? 1 : 10, fallback: type.isShelf ? 1 : 0.70710678)
        return b
    }
    public var dspBand: MixerEQBand {
        let b = sanitized()
        return MixerEQBand(
            type: b.type.rawValue, frequency: Float(b.frequency), gain: Float(b.gain), q: Float(b.q), enabled: b.enabled
        )
    }
}
private func bounded(_ x: Double, _ lo: Double, _ hi: Double, fallback: Double = 0) -> Double {
    x.isFinite ? min(hi, max(lo, x)) : fallback
}

public struct MixerSettings: Codable, Equatable, Sendable {
    public var volume: Double = 1
    public var muted: Bool = false
    public var enabled: Bool = true
    public var bands: [EQBand] = defaultBands
    public static let defaultBands: [EQBand] = [
        .init(type: .lowShelf, frequency: 180, q: 1),
        .init(frequency: 500), .init(frequency: 1000), .init(frequency: 3000),
        .init(type: .highShelf, frequency: 5000, q: 1),
    ]
    public init() {}
    public var isFlat: Bool { volume == 1 && !muted && bands.allSatisfy(\.isFlat) }
    public var needsProcessing: Bool { enabled && !isFlat }
    public var shouldPersist: Bool { !enabled || self != MixerSettings() }
    // Compatibility accessors for the original three-band settings and presets.
    public var bass: Double {
        get { bands[0].gain }
        set { bands[0].gain = newValue }
    }
    public var mid: Double {
        get { bands[2].gain }
        set { bands[2].gain = newValue }
    }
    public var treble: Double {
        get { bands[4].gain }
        set { bands[4].gain = newValue }
    }
    public var dspBands: [MixerEQBand] { bands.map(\.dspBand) }
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        let b = dspBands
        return b.withUnsafeBufferPointer { MixerEQResponse($0.baseAddress, UInt32($0.count), sampleRate, frequency) }
    }
    public func sanitized() -> Self {
        var copy = self
        copy.volume = bounded(volume, 0, 1, fallback: 1)
        copy.bands = Array(bands.prefix(5)).map { $0.sanitized() }
        while copy.bands.count < 5 { copy.bands.append(Self.defaultBands[copy.bands.count]) }
        return copy
    }
    enum CodingKeys: String, CodingKey { case volume, muted, enabled, bands, bass, mid, treble }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? Self.defaultBands
        if !c.contains(.bands) {
            bass = try c.decodeIfPresent(Double.self, forKey: .bass) ?? 0
            mid = try c.decodeIfPresent(Double.self, forKey: .mid) ?? 0
            treble = try c.decodeIfPresent(Double.self, forKey: .treble) ?? 0
        }
        self = sanitized()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volume, forKey: .volume)
        try c.encode(muted, forKey: .muted)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(bands, forKey: .bands)
    }
}
