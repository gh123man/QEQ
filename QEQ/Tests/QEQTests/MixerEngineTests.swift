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
    var sourcePeak: Float { sourceLevel.withLock { $0 } }
    let sourceLevel = OSAllocatedUnfairLock<Float>(initialState: 0.3)
    let lifecycle = OSAllocatedUnfairLock(initialState: [String]())
    var lastFrames: UInt64 { 16384 }
    let level: OSAllocatedUnfairLock<Float>
    let reads: OSAllocatedUnfairLock<Int>
    init(level: OSAllocatedUnfairLock<Float>, reads: OSAllocatedUnfairLock<Int>) {
        self.level = level
        self.reads = reads
    }
    func update(_ settings: MixerSettings, global: MixerSettings) { lifecycle.withLock { $0.append("update") } }
    func analysis(using analyzer: SpectrumAnalyzer) -> AudioTelemetry? {
        reads.withLock { $0 += 1 }
        var value = AudioTelemetry()
        value.peak = peak
        value.spectrum = [Float](repeating: peak > 0 ? -20 : -90, count: AudioTelemetry.spectrumBinCount)
        return value
    }
    func checkHealth() throws { lifecycle.withLock { $0.append("health") } }
    func stop() { lifecycle.withLock { $0.append("stop") } }
}

@Test func openingClosingAndSelectingEQCannotDiscoverOrReconfigureAudioRoutes() async throws {
    let route = MeterRoute(level: .init(initialState: 0.1), reads: .init(initialState: 0))
    let creates = OSAllocatedUnfairLock(initialState: 0)
    let discoveries = OSAllocatedUnfairLock(initialState: 0)
    let ready = OSAllocatedUnfairLock(initialState: false)
    let finished = OSAllocatedUnfairLock(initialState: false)
    let controller = RouteController { _, _, _, _ in
        creates.withLock { $0 += 1 }
        return route
    }
    let engine = MixerEngine(
        controller: controller,
        discover: {
            discoveries.withLock { $0 += 1 }
            return [AudioApplication(id: "test", name: "Test", processes: [10], playing: true)]
        }, readOutput: { route.output }, discoveryInterval: 60)
    defer { engine.shutdown() }
    engine.start(settings: [:], enabled: true) { snapshot in
        ready.withLock { $0 = snapshot.active == ["test"] }
    }
    func wait(_ flag: OSAllocatedUnfairLock<Bool>) async throws {
        for _ in 0..<300 {
            if flag.withLock({ $0 }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flag.withLock { $0 }, "Engine did not finish within 3 seconds")
    }
    try await wait(ready)
    let before = route.lifecycle.withLock { $0 }
    // A running flat app must already have its route before the first opening.
    #expect(creates.withLock { $0 } == 1)
    for _ in 0..<100 {
        engine.setAnalysisApp(MixerEngine.globalEQID, includeGlobal: true) { _ in }
        engine.setAnalysisApp("test", includeGlobal: true) { _ in }
        engine.setAnalysisApp(nil) { _ in }
    }
    engine.setAnalysisApp(nil) { _ in finished.withLock { $0 = true } }
    try await wait(finished)
    #expect(discoveries.withLock { $0 } == 1)
    #expect(creates.withLock { $0 } == 1)
    #expect(route.lifecycle.withLock { $0 } == before)
    #expect(route.reads.withLock { $0 } > 0)

    // Resetting/bypassing an app must not put the next popup opening back on
    // the old create/stop path either. Only the explicit master bypass stops it.
    var bypassed = MixerSettings()
    bypassed.enabled = false
    finished.withLock { $0 = false }
    engine.update("test", settings: bypassed)
    engine.update("test", settings: MixerSettings())
    engine.setGlobalEQ(MixerSettings())
    engine.setAnalysisApp(nil) { _ in finished.withLock { $0 = true } }
    try await wait(finished)
    #expect(route.lifecycle.withLock { $0 } == before + ["update", "update", "update"])
    engine.shutdown()
    #expect(route.lifecycle.withLock { $0.last } == "stop")
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
    // Source-only changes must still reach the row while output remains silent.
    route.sourceLevel.withLock { $0 = 0.6 }
    try await wait { values.withLock { $0.last?.apps["test"]?.sourcePeak == 0.6 } }
    #expect(values.withLock { $0.last?.peak } == 0)
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
    // Excluding a live app releases its route and its spectrum immediately,
    // even while global EQ would otherwise require processing.
    var global = MixerSettings()
    global.bass = 6
    engine.setGlobalEQ(global)
    engine.setExcludedApps(["test"])
    try await wait { values.withLock { $0.last == AudioTelemetry() } }
    let excludedReads = reads.withLock { $0 }
    try await Task.sleep(for: .milliseconds(250))
    #expect(reads.withLock { $0 } == excludedReads)
    engine.setExcludedApps([])
    try await wait { values.withLock { $0.last?.peak == 0.2 } }
}
