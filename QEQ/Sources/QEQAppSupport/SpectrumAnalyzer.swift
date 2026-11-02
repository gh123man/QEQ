import Accelerate
import Foundation
import MixerDSP

public struct AudioTelemetry: Sendable {
    public var spectrum: [Float] = []
    public var peak: Float = 0
    public var limitingDB: Float = 0
    public var apps: [String: AudioTelemetry] = [:]
    public var simulated = false
    public init() {}
    /// Strongest app in each bin, not a phase-aligned measurement of the final mix.
    static func envelope(_ values: [Self]) -> Self {
        var result = Self()
        for value in values {
            result.peak = max(result.peak, value.peak)
            result.limitingDB = max(result.limitingDB, value.limitingDB)
            if result.spectrum.isEmpty {
                result.spectrum = value.spectrum
            } else if result.spectrum.count == value.spectrum.count {
                result.spectrum = zip(result.spectrum, value.spectrum).map { max($0, $1) }
            }
        }
        return result
    }
}

/// Runs on the control queue, never the realtime callback. The DSP exports a
/// bounded atomic snapshot; a concurrent write skips this visual frame.
final class SpectrumAnalyzer {
    static let count = Int(MixerAnalysisFrameCount)
    static let bins = 96
    private let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD)
    private let window = (0..<count).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count))) }
    private var left = [Float](repeating: 0, count: count)
    private var right = [Float](repeating: 0, count: count)
    private var imaginary = [Float](repeating: 0, count: count)
    private var realOutput = [Float](repeating: 0, count: count)
    private var imaginaryOutput = [Float](repeating: 0, count: count)
    private var powers = [Float](repeating: 0, count: count / 2)
    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }
    func read(dsp: OpaquePointer, sampleRate: Double) -> AudioTelemetry? {
        guard MixerDSPReadAnalysis(dsp, &left, &right, UInt32(Self.count)) else { return nil }
        var value = AudioTelemetry()
        value.peak = MixerDSPPeak(dsp)
        value.limitingDB = MixerDSPLimitingDB(dsp)
        value.spectrum = spectrum(left: left, right: right, sampleRate: sampleRate)
        return value
    }
    func spectrum(left: [Float], right: [Float], sampleRate: Double) -> [Float] {
        guard let setup, left.count == Self.count, right.count == Self.count else { return [] }
        powers = [Float](repeating: 0, count: Self.count / 2)
        let scale = 2 / window.reduce(0, +)
        for channel in [left, right] {
            var windowed = zip(channel, window).map(*)
            vDSP_DFT_Execute(setup, &windowed, &imaginary, &realOutput, &imaginaryOutput)
            for i in 0..<powers.count {
                powers[i] +=
                    (realOutput[i] * realOutput[i] + imaginaryOutput[i] * imaginaryOutput[i]) * scale * scale / 2
            }
        }
        let upper = min(20000, sampleRate * 0.45)
        var result = [Float](repeating: -90, count: Self.bins)
        func power(at position: Double) -> Float {
            let position = min(Double(powers.count - 1), max(0, position))
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            return powers[lower] * (1 - fraction) + powers[min(lower + 1, powers.count - 1)] * fraction
        }
        for i in 0..<Self.bins {
            let low = 20 * pow(upper / 20, Double(i) / Double(Self.bins))
            let high = 20 * pow(upper / 20, Double(i + 1) / Double(Self.bins))
            let lowBin = low / sampleRate * Double(Self.count)
            let highBin = high / sampleRate * Double(Self.count)
            var peak = max(power(at: lowBin), power(at: highBin))
            let start = max(1, Int(ceil(lowBin)))
            let end = min(powers.count - 1, Int(floor(highBin)))
            if start <= end { peak = max(peak, powers[start...end].max() ?? 0) }
            // No extra peak hold: a cut or mute must reflect the current window.
            result[i] = max(-90, min(0, 10 * log10(max(1e-9, peak))))
        }
        return result
    }
}
