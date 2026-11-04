import Combine
import Foundation
import QEQCore

/// Main-thread UI readings, published independently of settings and app discovery.
/// Identical (including silent) frames cause no view invalidations.
@MainActor
public final class LiveAudioTelemetry: ObservableObject {
    @Published public private(set) var value = AudioTelemetry()

    public init() {}

    public func update(_ reading: AudioTelemetry) {
        guard reading != value else { return }
        value = reading
    }

    public func reading(for appID: String) -> AudioTelemetry {
        appID == MixerEngine.globalEQID ? value : value.apps[appID] ?? AudioTelemetry()
    }
}

/// Publish visible text only when its displayed precision changes. No throttling:
/// a new status reaches the UI in the same telemetry frame.
public struct AudioDisplayStatus: Equatable, Sendable {
    public var hasSpectrum = false
    public var simulated = false
    public var peak = "−∞ dBFS"
    public var limiting: String?

    public init() {}

    public init(_ telemetry: AudioTelemetry, appID: String) {
        let value = appID == MixerEngine.globalEQID ? telemetry : telemetry.apps[appID] ?? AudioTelemetry()
        hasSpectrum = !value.spectrum.isEmpty
        simulated = value.simulated
        peak = value.peak > 0.00003 ? String(format: "%.0f dBFS", 20 * log10(value.peak)) : "−∞ dBFS"
        limiting = value.limitingDB > 0.1 ? String(format: "Limiting −%.1f dB", value.limitingDB) : nil
    }
}
