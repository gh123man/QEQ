import CoreAudio
import Foundation
import MixerDSP
import Testing

@testable import QEQAppSupport
@testable import QEQCore

private func render(
    frequency: Double = 80, volume: Float = 1, bass: Float = 0, mid: Float = 0, treble: Float = 0, muted: Bool = false,
    channels: Int = 2, rate: Double = 48000
) -> [Float] {
    let frames = Int(rate / 4)
    let dsp = MixerDSPCreate(rate, UInt32(channels), 1)!
    defer { MixerDSPDestroy(dsp) }
    MixerDSPSet(dsp, volume, bass, mid, treble, muted)
    var input = (0..<(frames * channels)).map { Float(0.1 * sin(2 * .pi * frequency * Double($0 / channels) / rate)) }
    var output = [Float](repeating: 99, count: input.count)
    input.withUnsafeMutableBytes { i in
        output.withUnsafeMutableBytes { o in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(i.count), mData: i.baseAddress))
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(o.count), mData: o.baseAddress))
            MixerDSPProcess(dsp, &inABL, &outABL)
        }
    }
    #expect(MixerDSPFrames(dsp) == UInt64(frames))
    #expect(MixerDSPFaults(dsp) == 0)
    return Array(output.suffix(frames * channels / 2))
}
private func rms(_ samples: [Float]) -> Double {
    sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
}
@Test func neutralPathPreservesSineAndVolumeScalesLinearly() {
    let full = render(frequency: 1000)
    let half = render(frequency: 1000, volume: 0.5)
    #expect(abs(rms(full) - 0.1 / sqrt(2)) < 0.00001)
    #expect(abs(rms(half) / rms(full) - 0.5) < 0.00001)
}
@Test func appVolumeBoostRaisesQuietAudioAndLeavesOtherProcessorsUnchanged() {
    for rate in [44100.0, 48000, 96000] {
        let normal = rms(render(frequency: 1000, rate: rate))
        #expect(abs(rms(render(frequency: 1000, volume: 2, rate: rate)) / normal - 2) < 0.0001)
        #expect(abs(rms(render(frequency: 1000, volume: 1.5, rate: rate)) / normal - 1.5) < 0.0001)
        #expect(abs(rms(render(frequency: 1000, rate: rate)) - normal) < 0.0001)
        #expect(rms(render(volume: 2, muted: true, rate: rate)) == 0)
        // Invalid direct DSP callers cannot exceed the supported boost range.
        #expect(abs(rms(render(frequency: 1000, volume: 20, rate: rate)) / normal - 2) < 0.0001)
    }
}

@Test func boostedVolumePersistsAndDisablingBoostRestoresUnityCeiling() throws {
    var settings = MixerSettings()
    settings.boostEnabled = true
    settings.volume = 1.75
    let restored = try JSONDecoder().decode(MixerSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored == settings)
    #expect(restored.needsProcessing)
    #expect(restored.shouldPersist)
    settings.volume = 12
    #expect(settings.sanitized().volume == 2)
    settings.boostEnabled = false
    #expect(settings.sanitized().volume == 1)
    let legacy = try JSONDecoder().decode(MixerSettings.self, from: Data(#"{"volume":0.65}"#.utf8))
    #expect(!legacy.boostEnabled && legacy.volume == 0.65)
    settings.boostEnabled = true
    settings.volume = 1
    #expect(!settings.needsProcessing)
    #expect(settings.shouldPersist)
}

@Test func volumeBoostRetainsStereoPeakProtectionAndOutputTelemetry() {
    let dsp = MixerDSPCreate(48000, 2, 1)!
    defer { MixerDSPDestroy(dsp) }
    MixerDSPConfigure(dsp, 2, false, nil, 0)
    _ = processSamples([Float](repeating: 0, count: 4096), channels: 2, dsp: dsp)
    let result = processSamples([0.8, -0.4], channels: 2, dsp: dsp)
    #expect(abs(result[0] - 1) < 0.00001)
    #expect(abs(result[1] + 0.5) < 0.00001)
    #expect(abs(MixerDSPPeak(dsp) - 1) < 0.00001)
    #expect(MixerDSPLimitingDB(dsp) > 4)
}
@Test func bassCutAttenuatesLowFrequenciesWithoutChangingOtherApps() {
    let low = rms(render(frequency: 60, bass: -12)) / rms(render(frequency: 60))
    let high = rms(render(frequency: 2000, bass: -12)) / rms(render(frequency: 2000))
    #expect(low > 0.24 && low < 0.28)
    #expect(high > 0.99 && high < 1.01)
    // A separate processor keeps its own neutral state.
    #expect(abs(rms(render(frequency: 60)) - 0.1 / sqrt(2)) < 0.0001)
}
@Test func bassBoostRaisesBassWithoutTurningDownUnrelatedFrequencies() {
    for rate in [44100.0, 48000, 96000] {
        let bassDB =
            20 * log10(rms(render(frequency: 60, bass: 12, rate: rate)) / rms(render(frequency: 60, rate: rate)))
        let highDB =
            20 * log10(rms(render(frequency: 4000, bass: 12, rate: rate)) / rms(render(frequency: 4000, rate: rate)))
        print("+12 dB bass @ \(rate): bass \(bassDB) dB, highs \(highDB) dB")
        #expect(bassDB > 11.5 && bassDB < 12.1)
        #expect(abs(highDB) < 0.05)
    }
}
@Test func otherBandsAndSampleRates() {
    for rate in [44100.0, 48000, 96000] {
        let middle = rms(render(frequency: 1000, mid: -12, rate: rate)) / rms(render(frequency: 1000, rate: rate))
        let high = rms(render(frequency: 16000, treble: -12, rate: rate)) / rms(render(frequency: 16000, rate: rate))
        #expect(middle > 0.24 && middle < 0.27)
        #expect(high > 0.24 && high < 0.3)
    }
}
@Test func muteAndZeroGainAreSilentAfterRamp() {
    #expect(rms(render(muted: true)) == 0)
    #expect(rms(render(volume: 0)) == 0)
}

@Test func mutedSourceMeterTracksLiveInputWithoutLeakingAudio() {
    for channels in [1, 2] {
        let dsp = MixerDSPCreate(48000, UInt32(channels), 1)!
        defer { MixerDSPDestroy(dsp) }
        MixerDSPConfigure(dsp, 2, true, nil, 0)
        _ = processSamples([Float](repeating: 0, count: 1024 * channels), channels: channels, dsp: dsp)
        // No spectrum window or analysis enablement is needed for source peaks.
        for source in [Float(0.4), 0.1, 0, 0.7] {
            let input = (0..<(512 * channels)).map { $0 % 2 == 0 ? source : -source }
            let output = processSamples(input, channels: channels, dsp: dsp)
            #expect(output.allSatisfy { $0 == 0 })
            #expect(MixerDSPPeak(dsp) == 0)
            #expect(abs(MixerDSPSourcePeak(dsp) - source) < 0.00001)
        }
        MixerDSPConfigure(dsp, 1, false, nil, 0)
        _ = processSamples([Float](repeating: 0.1, count: 2048 * channels), channels: channels, dsp: dsp)
        #expect(abs(MixerDSPPeak(dsp) - 0.1) < 0.00001)
        #expect(abs(MixerDSPSourcePeak(dsp) - 0.1) < 0.00001)
    }
}
@Test func monoIsSupportedAndInvalidFormatsRejected() {
    #expect(abs(rms(render(channels: 1)) - 0.1 / sqrt(2)) < 0.0001)
    #expect(MixerDSPCreate(48000, 8, 1) == nil)
    #expect(MixerDSPCreate(.nan, 2, 1) == nil)
}
@Test func boostedEQRemainsFiniteWithPeakProtection() {
    let output = render(frequency: 1000, bass: 12, mid: 12, treble: 12)
    #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
    #expect(rms(output) > 0.1)
}
@Test func planarStereoSkipsPhysicalInputAndKeepsChannelsSeparate() {
    let count = 512
    let dsp = MixerDSPCreate(48000, 2, 2)!
    defer { MixerDSPDestroy(dsp) }
    let inputs = AudioBufferList.allocate(maximumBuffers: 3)
    let outputs = AudioBufferList.allocate(maximumBuffers: 2)
    defer {
        inputs.unsafeMutablePointer.deallocate()
        outputs.unsafeMutablePointer.deallocate()
    }
    var mic = [Float](repeating: 0.9, count: count)
    var left = [Float](repeating: 0.1, count: count)
    var right = [Float](repeating: -0.2, count: count)
    var outLeft = [Float](repeating: 99, count: count)
    var outRight = [Float](repeating: 99, count: count)
    mic.withUnsafeMutableBytes { m in
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                outLeft.withUnsafeMutableBytes { ol in
                    outRight.withUnsafeMutableBytes { or in
                        inputs[0] = AudioBuffer(
                            mNumberChannels: 1, mDataByteSize: UInt32(m.count), mData: m.baseAddress)
                        inputs[1] = AudioBuffer(
                            mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                        inputs[2] = AudioBuffer(
                            mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                        outputs[0] = AudioBuffer(
                            mNumberChannels: 1, mDataByteSize: UInt32(ol.count), mData: ol.baseAddress)
                        outputs[1] = AudioBuffer(
                            mNumberChannels: 1, mDataByteSize: UInt32(or.count), mData: or.baseAddress)
                        MixerDSPProcess(dsp, inputs.unsafePointer, outputs.unsafeMutablePointer)
                    }
                }
            }
        }
    }
    #expect(outLeft.allSatisfy { abs($0 - 0.1) < 0.00001 })
    #expect(outRight.allSatisfy { abs($0 + 0.2) < 0.00001 })
    #expect(abs(MixerDSPSourcePeak(dsp) - 0.2) < 0.00001)  // Excludes the 0.9 physical input.
}
@Test func invalidBufferLayoutClearsOutputAndReportsFault() {
    let dsp = MixerDSPCreate(48000, 2, 2)!
    defer { MixerDSPDestroy(dsp) }
    var output = [Float](repeating: 1, count: 16)
    output.withUnsafeMutableBytes { bytes in
        var input = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        var out = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        MixerDSPProcess(dsp, &input, &out)
    }
    #expect(output.allSatisfy { $0 == 0 })
    #expect(MixerDSPFaults(dsp) == 1)
}
@Test func savedSettingsRoundTripAndSanitize() throws {
    var settings = MixerSettings()
    settings.bass = -12
    settings.volume = 0.6
    let restored = try JSONDecoder().decode(MixerSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored == settings)
    #expect(!restored.isFlat)
    settings.volume = .nan
    settings.treble = 100
    #expect(settings.sanitized().volume == 1)
    #expect(settings.sanitized().treble == 18)
}
// Read-only integration check: no tap creation, capture, or permission prompt.
@Test(.enabled(if: ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0"))
func liveCoreAudioDiscovery() throws {
    let output = try HAL.output()
    #expect(output.id != 0)
    #expect(output.sampleRate > 0)
    let apps = try HAL.applications()
    #expect(Set(apps.map(\.id)).count == apps.count)
    for app in apps where app.id.lowercased().contains("chrome") {
        print("Resolved Chrome: \(app.name), \(app.id), \(app.path ?? "none"), clients=\(app.processes)")
    }
    print("Core Audio: \(output.name), \(output.sampleRate) Hz, \(output.bufferFrames) frames; \(apps.count) apps")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0"))
func bypassDoesNotCreateAudioTapsOrChangeDefaultOutput() async throws {
    let originalOutput = try HAL.uint(HAL.system, kAudioHardwarePropertyDefaultOutputDevice)
    let originalTaps = Set(try HAL.objects(HAL.system, kAudioHardwarePropertyTapList))
    let engine = MixerEngine()
    let snapshots = AsyncStream<MixerSnapshot> { continuation in
        engine.start(settings: [:]) { continuation.yield($0) }
    }
    var iterator = snapshots.makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.enabled == false)
    #expect(initial?.active.isEmpty == true)
    engine.setEnabled(true)
    let enabled = await iterator.next()
    #expect(enabled?.enabled == true)
    #expect(enabled?.active.isEmpty == true)
    engine.setEnabled(false)
    let bypassed = await iterator.next()
    #expect(bypassed?.enabled == false)
    #expect(bypassed?.active.isEmpty == true)
    engine.shutdown()
    #expect(try HAL.uint(HAL.system, kAudioHardwarePropertyDefaultOutputDevice) == originalOutput)
    #expect(Set(try HAL.objects(HAL.system, kAudioHardwarePropertyTapList)) == originalTaps)
}

@Test func appListHidesUnusedClientsButKeepsPausedAndConfiguredApps() {
    var list = AudioAppList()
    var music = AudioApplication(id: "music", name: "Music", path: nil, processes: [101, 102], playing: true)
    let background = AudioApplication(id: "background", name: "Background", path: nil, processes: [103], playing: false)
    let zoom = AudioApplication(id: "zoom", name: "Zoom", path: nil, processes: [104], playing: false)
    var zoomSettings = MixerSettings()
    zoomSettings.bass = -12
    let settings = ["zoom": zoomSettings]
    let visible = list.visibleApps(from: [background, music, zoom], settings: settings)
    #expect(visible.map(\.id) == ["music", "zoom"])
    #expect(visible[0].processes == [101, 102])  // Preserve all helper processes for a visible app.
    music.playing = false
    #expect(list.visibleApps(from: [background, music, zoom], settings: settings).map(\.id) == ["music", "zoom"])
    #expect(list.visibleApps(from: [background, music, zoom], settings: [:]).map(\.id) == ["music"])
}

@Test func appListDropsClosedClientsAndDoesNotRestoreStaleProcessIDs() {
    var list = AudioAppList()
    let playing = AudioApplication(id: "music", name: "Music", path: nil, processes: [101], playing: true)
    #expect(list.visibleApps(from: [playing], settings: [:]).count == 1)
    #expect(list.visibleApps(from: [], settings: [:]).isEmpty)
    var relaunched = AudioApplication(id: "music", name: "Music", path: nil, processes: [202], playing: false)
    #expect(list.visibleApps(from: [relaunched], settings: [:]).isEmpty)
    relaunched.playing = true
    #expect(list.visibleApps(from: [relaunched], settings: [:]).first?.processes == [202])
}

@Test func legacySettingsMigrateAndAppBypassKeepsAdjustments() throws {
    let data = Data(#"{"volume":0.6,"bass":-12,"mid":2,"treble":-3,"muted":false}"#.utf8)
    var settings = try JSONDecoder().decode(MixerSettings.self, from: data)
    #expect(settings.bands.count == 5)
    #expect(settings.bass == -12 && settings.mid == 2 && settings.treble == -3)
    #expect(settings.needsProcessing)
    settings.enabled = false
    #expect(!settings.needsProcessing && settings.shouldPersist)
    let restored = try JSONDecoder().decode(MixerSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored == settings)
    settings.enabled = true
    #expect(settings.needsProcessing && settings.volume == 0.6)
    settings.bands = []
    #expect(settings.sanitized().bands.count == 5)
}

@Test func helperIdentityResolvesContainingAppInsteadOfHelper() {
    let helper = URL(
        fileURLWithPath:
            "/Applications/Google Chrome.app/Contents/Frameworks/Chrome.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Helper"
    )
    #expect(AppIdentity.containingApp(helper)?.path == "/Applications/Google Chrome.app")
    #expect(AppIdentity.containingApp(URL(fileURLWithPath: "/usr/bin/afplay")) == nil)
    #expect(
        AppIdentity.containingApp(
            URL(fileURLWithPath: "/Applications/My.app backup/Browser.app/Contents/MacOS/Browser"))?.path
            == "/Applications/My.app backup/Browser.app")
}

private func renderParametric(
    _ settings: MixerSettings, frequency: Double, rate: Double = 48000,
    global: MixerSettings = MixerSettings()
) -> Double {
    let count = 48000
    let dsp = MixerDSPCreate(rate, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    let bands = settings.processingBands(global: global)
    bands.withUnsafeBufferPointer {
        MixerDSPConfigure(dsp, Float(settings.volume), settings.muted, $0.baseAddress, UInt32($0.count))
    }
    var input = (0..<count).map { Float(0.05 * sin(2 * .pi * frequency * Double($0) / rate)) }
    var output = [Float](repeating: 0, count: count)
    input.withUnsafeMutableBytes { i in
        output.withUnsafeMutableBytes { o in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(i.count), mData: i.baseAddress))
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o.count), mData: o.baseAddress))
            MixerDSPProcess(dsp, &inABL, &outABL)
        }
    }
    #expect(output.allSatisfy { $0.isFinite })
    return 20 * log10(rms(Array(output.suffix(count / 2))) / rms(Array(input.suffix(count / 2))))
}

@Test func globalAndAppFiltersComposeAndBypassIndependently() {
    var app = MixerSettings()
    app.bass = -6
    var global = MixerSettings()
    global.bass = 3
    global.treble = -4
    for rate in [44100.0, 48000, 96000] {
        for hz in [60.0, 1000, 12000] {
            let combined = renderParametric(app, frequency: hz, rate: rate, global: global)
            #expect(
                abs(combined - app.responseDB(at: hz, sampleRate: rate) - global.responseDB(at: hz, sampleRate: rate))
                    < 0.12)
            var bypassedApp = app
            bypassedApp.enabled = false
            #expect(
                abs(
                    renderParametric(bypassedApp, frequency: hz, rate: rate, global: global)
                        - global.responseDB(at: hz, sampleRate: rate)) < 0.12)
            var bypassedGlobal = global
            bypassedGlobal.enabled = false
            #expect(
                abs(
                    renderParametric(app, frequency: hz, rate: rate, global: bypassedGlobal)
                        - app.responseDB(at: hz, sampleRate: rate)) < 0.12)
        }
    }
}

@Test func parametricGraphMatchesActualDSPForAllFilterTypes() {
    for type in EQFilter.allCases {
        for rate in [44100.0, 48000, 96000] {
            var settings = MixerSettings()
            settings.bands[2] = EQBand(type: type, frequency: 1000, gain: -8, q: type.isShelf ? 0.5 : 2)
            for frequency in [250.0, 1000, 4000] {
                let actual = renderParametric(settings, frequency: frequency, rate: rate)
                let predicted = settings.responseDB(at: frequency, sampleRate: rate)
                #expect(
                    abs(actual - predicted) < 0.08,
                    "\(type) \(frequency) Hz @ \(rate): actual \(actual), graph \(predicted)")
            }
        }
    }
}

@Test func parametricQChangesWidthAndBandBypassIsNeutral() {
    var settings = MixerSettings()
    settings.bands[2] = EQBand(frequency: 1000, gain: -12, q: 0.5)
    let broad = settings.responseDB(at: 1500, sampleRate: 48000)
    settings.bands[2].q = 6
    let narrow = settings.responseDB(at: 1500, sampleRate: 48000)
    #expect(broad < narrow - 4)
    #expect(abs(settings.responseDB(at: 1000, sampleRate: 48000) + 12) < 0.001)
    settings.bands[2].enabled = false
    #expect(settings.isFlat && !settings.needsProcessing)
    #expect(abs(settings.responseDB(at: 1000, sampleRate: 48000)) < 0.001)
}

@Test func spectrumDetectsToneWithoutCancellingOppositePhaseStereo() {
    let count = SpectrumAnalyzer.count
    let rate = 48000.0
    let tone = 46.0 * rate / Double(count)
    let left = (0..<count).map { Float(0.1 * sin(2 * .pi * tone * Double($0) / rate)) }
    let right = left.map { -$0 }
    let analyzer = SpectrumAnalyzer()
    let bins = analyzer.spectrum(left: left, right: right, sampleRate: rate)
    #expect(bins.count == AudioTelemetry.spectrumBinCount)
    let peak = bins.enumerated().max(by: { $0.element < $1.element })!
    let frequency = 20 * pow(1000, (Double(peak.offset) + 0.5) / Double(bins.count))
    #expect(abs(log2(frequency / tone)) < 0.2)
    #expect(abs(peak.element + 20) < 0.2)
    let silence = analyzer.spectrum(
        left: .init(repeating: 0, count: count), right: .init(repeating: 0, count: count), sampleRate: rate)
    #expect(silence.allSatisfy { $0 == -90 })
}

@Test func analysisSnapshotIsOptInAndDoesNotChangeAudio() {
    let dsp = MixerDSPCreate(48000, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    let count = SpectrumAnalyzer.count
    var left = [Float](repeating: 0, count: count)
    var right = left
    #expect(!MixerDSPReadAnalysis(dsp, &left, &right, UInt32(count)))
    MixerDSPEnableAnalysis(dsp, true)
    var input = [Float](repeating: 0.1, count: count * 2)
    var output = input
    input.withUnsafeMutableBytes { i in
        output.withUnsafeMutableBytes { o in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(i.count), mData: i.baseAddress))
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o.count), mData: o.baseAddress))
            MixerDSPProcess(dsp, &inABL, &outABL)
        }
    }
    #expect(output == input)
    #expect(MixerDSPReadAnalysis(dsp, &left, &right, UInt32(count)))
    #expect(left.allSatisfy { $0 == 0.1 } && left == right)
    MixerDSPEnableAnalysis(dsp, false)
    #expect(!MixerDSPReadAnalysis(dsp, &left, &right, UInt32(count)))
}

@Test func lowFrequencySpectrumPeaksAppearAtTheCorrectFrequency() {
    for rate in [44100.0, 48000, 96000] {
        for tone in [30.0, 60, 100] {
            let count = SpectrumAnalyzer.count
            let signal = (0..<count).map { Float(0.1 * sin(2 * .pi * tone * Double($0) / rate)) }
            let bins = SpectrumAnalyzer().spectrum(left: signal, right: signal, sampleRate: rate)
            let peak = bins.enumerated().max(by: { $0.element < $1.element })!
            let frequency = 20 * pow(1000, (Double(peak.offset) + 0.5) / Double(bins.count))
            print("Spectrum: \(tone) Hz at \(rate) Hz → \(frequency) Hz")
            #expect(abs(log2(frequency / tone)) < 0.18)
        }
    }
}

@Test func liveSpectrumReflectsEQCutBoostAndMuteWithoutPeakHoldMasking() throws {
    let rate = 48000.0
    let dsp = MixerDSPCreate(rate, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    MixerDSPEnableAnalysis(dsp, true)
    let analyzer = SpectrumAnalyzer()
    let signal = (0..<48000).map { Float(0.01 * sin(2 * .pi * 1000 * Double($0) / rate)) }
    let bin = Int(log(1000.0 / 20) / log(1000) * Double(SpectrumAnalyzer.bins))
    _ = processSamples(signal, channels: 1, dsp: dsp)
    let baseline = try #require(analyzer.read(dsp: dsp, sampleRate: rate)).spectrum[bin]
    for gain in [-18.0, 18] {
        var settings = MixerSettings()
        settings.bands[2].gain = gain
        let bands = settings.dspBands
        bands.withUnsafeBufferPointer { MixerDSPConfigure(dsp, 1, false, $0.baseAddress, UInt32($0.count)) }
        _ = processSamples(signal, channels: 1, dsp: dsp)
        let value = try #require(analyzer.read(dsp: dsp, sampleRate: rate))
        print("Spectrum EQ \(gain) dB → \(value.spectrum[bin] - baseline) dB change")
        #expect(abs(Double(value.spectrum[bin] - baseline) - gain) < 0.3)
        #expect(value.limitingDB == 0)
    }
    MixerDSPConfigure(dsp, 1, true, nil, 0)
    _ = processSamples(signal, channels: 1, dsp: dsp)
    // Peak is per callback; the large settling block includes the mute ramp.
    // The next hardware-sized callback must report zero after that ramp ends.
    _ = processSamples(Array(signal.prefix(512)), channels: 1, dsp: dsp)
    let muted = try #require(analyzer.read(dsp: dsp, sampleRate: rate))
    #expect(muted.spectrum.allSatisfy { $0 == -90 })
    #expect(muted.peak == 0)
    #expect(abs(muted.sourcePeak - 0.01) < 0.00001)
}

@Test func maximumBassCutLeavesMeasuredResidualAudioInsteadOfSilence() throws {
    let rate = 48000.0
    let frequency = 40.0
    let dsp = MixerDSPCreate(rate, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    MixerDSPEnableAnalysis(dsp, true)
    let analyzer = SpectrumAnalyzer()
    let input = (0..<48000).map { Float(0.1 * sin(2 * .pi * frequency * Double($0) / rate)) }
    _ = processSamples(input, channels: 1, dsp: dsp)
    let before = try #require(analyzer.read(dsp: dsp, sampleRate: rate))
    let bin = try #require(before.spectrum.enumerated().max(by: { $0.element < $1.element })).offset
    var settings = MixerSettings()
    settings.bass = -18
    let bands = settings.dspBands
    bands.withUnsafeBufferPointer { MixerDSPConfigure(dsp, 1, false, $0.baseAddress, UInt32($0.count)) }
    let output = processSamples(input, channels: 1, dsp: dsp)
    let after = try #require(analyzer.read(dsp: dsp, sampleRate: rate))
    let ratio = rms(Array(output.suffix(24000))) / rms(Array(input.suffix(24000)))
    let measuredDB = Double(after.spectrum[bin] - before.spectrum[bin])
    print("−18 dB bass at 40 Hz: amplitude \(ratio), spectrum change \(measuredDB) dB")
    #expect(ratio > 0.12 && ratio < 0.14)
    #expect(after.peak > 0 && after.spectrum[bin] > -90)
    #expect(abs(measuredDB - settings.responseDB(at: frequency, sampleRate: rate)) < 0.2)
}

private func processSamples(_ inputSamples: [Float], channels: Int, dsp: OpaquePointer) -> [Float] {
    var input = inputSamples
    var output = [Float](repeating: 0, count: input.count)
    input.withUnsafeMutableBytes { i in
        output.withUnsafeMutableBytes { o in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(i.count), mData: i.baseAddress))
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(o.count), mData: o.baseAddress))
            MixerDSPProcess(dsp, &inABL, &outABL)
        }
    }
    return output
}

@Test func peakProtectionIsImmediateStereoLinkedAndRecovers() {
    for rate in [44100.0, 48000, 96000] {
        let dsp = MixerDSPCreate(rate, 2, 1)!
        defer { MixerDSPDestroy(dsp) }
        let quiet: [Float] = [0.25, -0.5]
        #expect(processSamples(quiet, channels: 2, dsp: dsp) == quiet)
        #expect(MixerDSPLimitingDB(dsp) == 0)
        // The overload is contained in its original sample, and both channels
        // receive identical gain even though only the left exceeds full scale.
        let impulse = processSamples([2, -0.4], channels: 2, dsp: dsp)
        #expect(abs(impulse[0] - 1) < 0.000001)
        #expect(abs(impulse[1] + 0.2) < 0.000001)
        #expect(abs(MixerDSPLimitingDB(dsp) - 6.0206) < 0.001)
        let recovery = processSamples(
            Array(repeating: quiet, count: Int(rate / 2)).flatMap { $0 }, channels: 2, dsp: dsp)
        #expect(recovery.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(abs(recovery[0] - 0.125) < 0.001)
        #expect(abs(recovery[recovery.count - 2] - 0.25) < 0.00003)
        let settled = processSamples(quiet, channels: 2, dsp: dsp)
        #expect(abs(settled[1] + 0.5) < 0.00003)
        #expect(MixerDSPLimitingDB(dsp) < 0.001)
        let otherApp = MixerDSPCreate(rate, 2, 1)!
        defer { MixerDSPDestroy(otherApp) }
        #expect(processSamples(quiet, channels: 2, dsp: otherApp) == quiet)
    }
}

@Test func bassAndTrebleBoostsDoNotStackFullBandAttenuation() {
    var settings = MixerSettings()
    settings.bass = 12
    settings.treble = 12
    for rate in [44100.0, 48000, 96000] {
        for hz in [60.0, 1000, 16000] {
            let measured = renderParametric(settings, frequency: hz, rate: rate)
            #expect(abs(measured - settings.responseDB(at: hz, sampleRate: rate)) < 0.08)
        }
    }
}

@Test func loweringAppVolumeProvidesHeadroomBeforePeakProtection() {
    let dsp = MixerDSPCreate(48000, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    var settings = MixerSettings()
    settings.volume = 0.1
    settings.bass = 12
    let bands = settings.dspBands
    bands.withUnsafeBufferPointer {
        MixerDSPConfigure(dsp, Float(settings.volume), false, $0.baseAddress, UInt32($0.count))
    }
    // Settle the existing 10 ms parameter ramp before sending a loud signal.
    _ = processSamples([Float](repeating: 0, count: 1024), channels: 1, dsp: dsp)
    let input = (0..<48000).map { Float(0.8 * sin(2 * .pi * 60 * Double($0) / 48000)) }
    let output = processSamples(input, channels: 1, dsp: dsp)
    #expect(MixerDSPLimitingDB(dsp) == 0)
    let measured = 20 * log10(rms(Array(output.suffix(24000))) / rms(Array(input.suffix(24000))))
    #expect(abs(measured - (settings.responseDB(at: 60, sampleRate: 48000) - 20)) < 0.08)
}
