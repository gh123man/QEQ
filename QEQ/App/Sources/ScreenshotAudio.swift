import Accelerate
import Foundation
import QEQAppSupport

/// Offline documentation fixtures. Analyze synthesized PCM instead of drawing
/// periodic ripples in frequency space. Never touches an audio device.
enum ScreenshotAudio {
    enum Source { case music, voice, browser }

    static func spectrum(_ source: Source) -> [Float] {
        let count = 16384
        let rate = 48000.0
        var seed: UInt64 = source == .music ? 481 : (source == .voice ? 719 : 1223)
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        // Independent phases and strengths make each source a distinct snapshot.
        var partials: [(frequency: Double, amplitude: Double, phase: Double)] = []
        func harmonics(_ fundamental: Double, level: Double, voice: Bool) {
            for harmonic in 1...70 {
                let hz = fundamental * Double(harmonic)
                guard hz < 15000 else { break }
                var amplitude = level / pow(Double(harmonic), voice ? 0.85 : 1.3)
                if voice {
                    // Formants of a voiced vowel, with a natural upper rolloff.
                    func formant(_ center: Double, _ width: Double) -> Double {
                        exp(-0.5 * pow((hz - center) / width, 2))
                    }
                    amplitude *=
                        0.12 + 2.7 * formant(620, 150)
                        + 2.0 * formant(1480, 230) + 1.1 * formant(2650, 360)
                }
                amplitude *= 0.7 + 0.6 * random()
                partials.append((hz, amplitude, random() * 2 * .pi))
            }
        }
        switch source {
        case .music:
            harmonics(55, level: 0.22, voice: false)
            for note in [164.81, 220.0, 261.63, 329.63] {
                harmonics(note, level: 0.045, voice: false)
            }
        case .voice:
            harmonics(137, level: 0.32, voice: true)
        case .browser:
            harmonics(193, level: 0.22, voice: true)
            harmonics(73.42, level: 0.055, voice: false)
        }
        var samples = [Float](repeating: 0, count: count)
        var slow = 0.0
        var middle = 0.0
        var fast = 0.0
        var previous = 0.0
        for index in 0..<count {
            let time = Double(index) / rate
            let white = 2 * random() - 1
            slow = 0.995 * slow + 0.005 * white
            middle = 0.95 * middle + 0.05 * white
            fast = 0.55 * fast + 0.45 * white
            let pink = 3 * slow + 1.5 * middle + 0.35 * fast
            var signal = 0.0
            for partial in partials {
                // Slight pitch motion and amplitude modulation in the PCM.
                let pitch = source == .music ? 0 : 0.006 * sin(2 * .pi * 4.7 * time)
                signal += partial.amplitude * sin(2 * .pi * partial.frequency * time + partial.phase + pitch)
            }
            if source == .music {
                let kick = 0.20 * exp(-time * 14) * sin(2 * .pi * (47 * time + 1.4 * (1 - exp(-time * 28))))
                let snare = 0.17 * exp(-max(0, time - 0.09) * 25) * (time > 0.09 ? fast : 0)
                signal += 0.20 * pink + kick + snare
            } else {
                let syllable = 0.65 + 0.35 * exp(-pow((time - 0.17) / 0.09, 2))
                signal = signal * syllable + 0.045 * pink + 0.025 * (fast - previous)
            }
            previous = fast
            // Same Hann window and amplitude normalization as the live analyzer.
            samples[index] = Float(signal * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count))))
        }
        let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD)!
        defer { vDSP_DFT_DestroySetup(setup) }
        var imaginary = [Float](repeating: 0, count: count)
        var real = imaginary
        var imag = imaginary
        vDSP_DFT_Execute(setup, &samples, &imaginary, &real, &imag)
        let scale = Float(4.0 / Double(count))
        let powers = (0..<count / 2).map { (real[$0] * real[$0] + imag[$0] * imag[$0]) * scale * scale }
        func power(at position: Double) -> Float {
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            return powers[lower] * (1 - fraction) + powers[lower + 1] * fraction
        }
        let bins = AudioTelemetry.spectrumBinCount
        return (0..<bins).map { index in
            let low = 20 * pow(1000, Double(index) / Double(bins)) / rate * Double(count)
            let high = 20 * pow(1000, Double(index + 1) / Double(bins)) / rate * Double(count)
            var peak = max(power(at: low), power(at: high))
            let start = max(1, Int(ceil(low)))
            let end = Int(floor(high))
            if start <= end { peak = max(peak, powers[start...end].max() ?? 0) }
            return max(-90, min(0, 10 * log10(max(1e-9, peak))))
        }
    }
}
