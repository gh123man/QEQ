import CoreAudio
import Foundation
import MixerDSP
import Testing

@testable import QEQAppSupport
@testable import QEQCore

// Opt-in Release microbenchmarks, with no taps, saved settings, or audio output.
// Run only this test to avoid competing with the parallel correctness suite.
@Test(.enabled(if: ProcessInfo.processInfo.environment["QEQ_PROFILE"] == "1"))
func profileComponents() throws {
    func measure(_ name: String, iterations: Int, _ work: () throws -> Void) rethrows {
        for _ in 0..<3 { try work() }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { try work() }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(
            String(
                format: "PROFILE %@: %.3f ms/iteration (%d iterations)", name, elapsed * 1000 / Double(iterations),
                iterations))
    }
    try measure("HAL discovery", iterations: 30) { _ = try HAL.applications() }
    let cache = AppIdentityCache()
    try measure("HAL discovery (cached metadata)", iterations: 30) { _ = try HAL.applications(identityCache: cache) }
    let signal = (0..<SpectrumAnalyzer.count).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / 48000)) }
    let analyzer = SpectrumAnalyzer()
    measure("stereo FFT + \(SpectrumAnalyzer.bins) bins", iterations: 1000) {
        _ = analyzer.spectrum(left: signal, right: signal, sampleRate: 48000)
    }
    var settings = MixerSettings()
    settings.bass = 6
    settings.mid = -3
    settings.treble = 4
    var checksum = 0.0
    measure("241-point EQ curve", iterations: 1000) {
        for index in 0...240 {
            checksum += settings.responseDB(at: 20 * pow(1000, Double(index) / 240), sampleRate: 48000)
        }
    }
    #expect(checksum.isFinite)
    let dsp = try #require(MixerDSPCreate(48000, 2, 1))
    defer { MixerDSPDestroy(dsp) }
    let bands = settings.processingBands(global: settings)
    bands.withUnsafeBufferPointer { MixerDSPConfigure(dsp, 0.5, false, $0.baseAddress, UInt32($0.count)) }
    var input = Array(signal.prefix(512))
    var output = [Float](repeating: 0, count: 512)
    input.withUnsafeMutableBytes { i in
        output.withUnsafeMutableBytes { o in
            var inputABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(i.count), mData: i.baseAddress))
            var outputABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(o.count), mData: o.baseAddress))
            for analysis in [false, true] {
                MixerDSPEnableAnalysis(dsp, analysis)
                measure("10-band DSP, 256 stereo frames, analysis=\(analysis)", iterations: 20000) {
                    MixerDSPProcess(dsp, &inputABL, &outputABL)
                }
            }
        }
    }
}
