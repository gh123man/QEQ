import Combine
import QEQAppSupport
import QEQCore
import Testing

@MainActor @Test func liveTelemetryPublishesChangesImmediatelyAndSkipsIdenticalFrames() {
    let store = LiveAudioTelemetry()
    var received: [AudioTelemetry] = []
    let subscription = store.$value.sink { received.append($0) }
    defer { subscription.cancel() }
    store.update(AudioTelemetry())
    #expect(received.count == 1)
    var frame = AudioTelemetry()
    frame.peak = 0.5
    frame.spectrum = [-60, -30, -10]
    frame.apps["app"] = frame
    store.update(frame)
    #expect(received.count == 2)
    #expect(received.last == frame)
    #expect(store.reading(for: MixerEngine.globalEQID) == frame)
    #expect(store.reading(for: "app") == frame.apps["app"])
    #expect(store.reading(for: "missing") == AudioTelemetry())
    store.update(frame)
    #expect(received.count == 2)
    // Source activity still updates while the app's output is muted.
    frame.apps["app"]?.peak = 0
    frame.apps["app"]?.sourcePeak = 0.8
    store.update(frame)
    #expect(received.count == 3)
    #expect(store.reading(for: "app").sourcePeak == 0.8)
    store.update(AudioTelemetry())
    #expect(received.count == 4)
    #expect(store.reading(for: "app") == AudioTelemetry())
}

@Test func displayStatusDeduplicatesOnlyInvisibleChanges() {
    var reading = AudioTelemetry()
    reading.spectrum = [-60, -30]
    reading.peak = 0.5
    let before = AudioDisplayStatus(reading, appID: MixerEngine.globalEQID)
    reading.peak = 0.501
    reading.spectrum = [-45, -10]
    #expect(AudioDisplayStatus(reading, appID: MixerEngine.globalEQID) == before)
    reading.peak = 0.1
    #expect(AudioDisplayStatus(reading, appID: MixerEngine.globalEQID).peak == "-20 dBFS")
    reading.limitingDB = 1.25
    #expect(AudioDisplayStatus(reading, appID: MixerEngine.globalEQID).limiting != nil)
    reading.limitingDB = 0
    reading.peak = 0
    let silent = AudioDisplayStatus(reading, appID: MixerEngine.globalEQID)
    #expect(silent.peak == "−∞ dBFS" && silent.limiting == nil && silent.hasSpectrum)
    reading.spectrum = []
    #expect(!AudioDisplayStatus(reading, appID: MixerEngine.globalEQID).hasSpectrum)
    #expect(AudioDisplayStatus(reading, appID: "absent") == AudioDisplayStatus())
}
