import CoreAudio
import Foundation
import QEQCore
import Testing
import os

@testable import QEQAppSupport

private final class MeterRoute: AudioRoute {
    let processes: [AudioObjectID] = [10]
    let output = OutputDevice(id: 20, uid: "test", name: "Test", sampleRate: 48000, bufferFrames: 256, channels: 2)
    var peak: Float { level.withLock { $0 } }
    var lastFrames: UInt64 { 16384 }
    let level: OSAllocatedUnfairLock<Float>
    let reads: OSAllocatedUnfairLock<Int>
    init(level: OSAllocatedUnfairLock<Float>, reads: OSAllocatedUnfairLock<Int>) {
        self.level = level
        self.reads = reads
    }
    func update(_ settings: MixerSettings, global: MixerSettings) {}
    func setAnalysis(_ enabled: Bool) {}
    func analysis(using analyzer: SpectrumAnalyzer) -> AudioTelemetry? {
        reads.withLock { $0 += 1 }
        var value = AudioTelemetry()
        value.peak = peak
        value.spectrum = [Float](repeating: peak > 0 ? -20 : -90, count: 96)
        return value
    }
    func checkHealth() throws {}
    func stop() {}
}

@Test func analysisSleepsWhenIdleAndRestartsAfterPlaybackBypassAndPanelChanges() async throws {
    let playing = OSAllocatedUnfairLock(initialState: false)
    let level = OSAllocatedUnfairLock<Float>(initialState: 0.1)
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let values = OSAllocatedUnfairLock(initialState: [AudioTelemetry]())
    let route = MeterRoute(level: level, reads: reads)
    let controller = RouteController { _, _, _, _ in route }
    let engine = MixerEngine(
        controller: controller,
        discover: {
            [AudioApplication(id: "test", name: "Test", processes: [10], playing: playing.withLock { $0 })]
        }, readOutput: { route.output })
    defer { engine.shutdown() }
    engine.start(settings: [:], enabled: true) { _ in }
    func show() {
        engine.setAnalysisApp(MixerEngine.globalEQID, includeGlobal: true) { value in
            values.withLock { $0.append(value) }
        }
    }
    func wait(until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Engine did not reach the expected state within 3 seconds")
    }
    show()
    try await wait { !values.withLock { $0.isEmpty } }
    try await Task.sleep(for: .milliseconds(250))
    #expect(values.withLock { $0.count } == 1)
    #expect(reads.withLock { $0 } == 0)

    // Discovery starts the visualizer without touching an EQ control.
    playing.withLock { $0 = true }
    try await wait { values.withLock { $0.last?.peak == 0.1 } }
    let count = values.withLock { $0.count }
    try await Task.sleep(for: .milliseconds(250))
    #expect(values.withLock { $0.count } == count)  // Identical frames do not redraw.
    level.withLock { $0 = 0 }
    try await wait { values.withLock { $0.last?.spectrum.first == -90 } }
    playing.withLock { $0 = false }
    try await wait { values.withLock { $0.last == AudioTelemetry() } }
    let idleReads = reads.withLock { $0 }
    try await Task.sleep(for: .milliseconds(250))
    #expect(reads.withLock { $0 } == idleReads)

    playing.withLock { $0 = true }
    level.withLock { $0 = 0.2 }
    try await wait { values.withLock { $0.last?.peak == 0.2 } }
    engine.setEnabled(false)
    try await wait { values.withLock { $0.last == AudioTelemetry() } }
    let disabledReads = reads.withLock { $0 }
    try await Task.sleep(for: .milliseconds(250))
    #expect(reads.withLock { $0 } == disabledReads)
    engine.setEnabled(true)
    try await wait { values.withLock { $0.last?.peak == 0.2 } }
    engine.setAnalysisApp(nil) { value in values.withLock { $0.append(value) } }
    try await wait { values.withLock { $0.last == AudioTelemetry() } }
    let hiddenReads = reads.withLock { $0 }
    try await Task.sleep(for: .milliseconds(250))
    #expect(reads.withLock { $0 } == hiddenReads)
    show()
    try await wait { values.withLock { $0.last?.peak == 0.2 } }
}
