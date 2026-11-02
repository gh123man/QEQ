import CoreAudio
import Foundation
import MixerDSP
import Testing

@testable import AppMixerAppSupport
@testable import AppMixerCore

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
@Test func bassCutAttenuatesLowFrequenciesWithoutChangingOtherApps() {
    let low = rms(render(frequency: 60, bass: -12)) / rms(render(frequency: 60))
    let high = rms(render(frequency: 2000, bass: -12)) / rms(render(frequency: 2000))
    #expect(low > 0.24 && low < 0.28)
    #expect(high > 0.99 && high < 1.01)
    // A separate processor keeps its own neutral state.
    #expect(abs(rms(render(frequency: 60)) - 0.1 / sqrt(2)) < 0.0001)
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
@Test func monoIsSupportedAndInvalidFormatsRejected() {
    #expect(abs(rms(render(channels: 1)) - 0.1 / sqrt(2)) < 0.0001)
    #expect(MixerDSPCreate(48000, 8, 1) == nil)
    #expect(MixerDSPCreate(.nan, 2, 1) == nil)
}
@Test func boostedEQRemainsFiniteWithConservativeHeadroom() {
    let output = render(frequency: 1000, bass: 12, mid: 12, treble: 12)
    #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
    #expect(rms(output) < 0.1)
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
@Test(.enabled(if: ProcessInfo.processInfo.environment["APP_MIXER_HARDWARE_TESTS"] != "0"))
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["APP_MIXER_HARDWARE_TESTS"] != "0"))
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

private func renderParametric(_ settings: MixerSettings, frequency: Double, rate: Double = 48000) -> Double {
    let count = 48000
    let dsp = MixerDSPCreate(rate, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    let bands = settings.dspBands
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

@Test func parametricGraphMatchesActualDSPForAllFilterTypes() {
    for type in EQFilter.allCases {
        for rate in [44100.0, 48000, 96000] {
            var settings = MixerSettings()
            settings.bands[2] = EQBand(type: type, frequency: 1000, gain: -8, q: type.isShelf ? 0.5 : 2)
            for frequency in [250.0, 1000, 4000] {
                let actual = renderParametric(settings, frequency: frequency, rate: rate)
                let predicted = settings.responseDB(at: frequency, sampleRate: rate) - settings.headroomDB
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
    let peak = bins.enumerated().max(by: { $0.element < $1.element })!
    let frequency = 20 * pow(1000, (Double(peak.offset) + 0.5) / Double(bins.count))
    #expect(abs(log2(frequency / tone)) < 0.2)
    #expect(abs(peak.element + 20) < 0.2)
    analyzer.reset()
    let silence = analyzer.spectrum(
        left: .init(repeating: 0, count: count), right: .init(repeating: 0, count: count), sampleRate: rate)
    #expect(silence.allSatisfy { $0 == -90 })
}

@Test func analysisSnapshotIsOptInAndDoesNotChangeAudio() {
    let dsp = MixerDSPCreate(48000, 1, 1)!
    defer { MixerDSPDestroy(dsp) }
    var left = [Float](repeating: 0, count: 2048)
    var right = left
    #expect(!MixerDSPReadAnalysis(dsp, &left, &right, 2048))
    MixerDSPEnableAnalysis(dsp, true)
    var input = [Float](repeating: 0.1, count: 4096)
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
    #expect(MixerDSPReadAnalysis(dsp, &left, &right, 2048))
    #expect(left.allSatisfy { $0 == 0.1 } && left == right)
    MixerDSPEnableAnalysis(dsp, false)
    #expect(!MixerDSPReadAnalysis(dsp, &left, &right, 2048))
}
