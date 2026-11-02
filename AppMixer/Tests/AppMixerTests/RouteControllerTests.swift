import AppMixerCore
import CoreAudio
import Foundation
import Testing

@testable import AppMixerAppSupport

private final class FakeRoute: AudioRoute {
    var processes: [AudioObjectID]
    let output: OutputDevice
    var peak: Float = 0
    var lastFrames: UInt64 = 0
    var stopped = false
    var stalled = false
    var checks = 0
    init(_ app: AudioApplication, _ output: OutputDevice) {
        processes = app.processes
        self.output = output
    }
    func update(_ settings: MixerSettings) {}
    func setAnalysis(_ enabled: Bool) {}
    func analysis(using analyzer: SpectrumAnalyzer) -> AudioTelemetry? { nil }
    func checkHealth() throws {
        checks += 1
        if stalled { throw AudioFailure(message: "No callbacks") }
        lastFrames += 512
    }
    func stop() { stopped = true }
}
private func usb(_ id: UInt32 = 10) -> OutputDevice {
    OutputDevice(id: id, uid: "usb-\(id)", name: "USB Output", sampleRate: 48000, bufferFrames: 256, channels: 2)
}
private var adjusted: MixerSettings {
    var value = MixerSettings()
    value.bass = -12
    return value
}

@Test func restoredIdleAppsDoNotAcquireRoutesOrTripTheWatchdog() throws {
    var created: [FakeRoute] = []
    let controller = RouteController { app, output, _ in
        let route = FakeRoute(app, output)
        created.append(route)
        return route
    }
    var idle = AudioApplication(id: "saved", name: "Saved app", processes: [20], playing: false)
    let live = AudioApplication(id: "live", name: "Playing app", processes: [30], playing: true)
    let saved = try JSONDecoder().decode(MixerSettings.self, from: JSONEncoder().encode(adjusted))
    let settings = ["saved": saved, "live": adjusted]
    for now in [0.0, 5, 30] {
        controller.reconcile(
            apps: [idle, live], output: usb(), settings: settings, enabled: true, analysisApp: nil, now: now)
    }
    #expect(created.count == 1 && Set(controller.routes.keys) == ["live"])
    #expect(controller.errors.isEmpty && controller.messages["saved"] == "Waiting for playback")
    idle.playing = true
    controller.reconcile(
        apps: [idle, live], output: usb(), settings: settings, enabled: true, analysisApp: nil, now: 31)
    #expect(created.count == 2 && controller.routes.count == 2)
    let savedRoute = created[1]
    savedRoute.stalled = true
    idle.playing = false
    controller.reconcile(
        apps: [idle, live], output: usb(), settings: settings, enabled: true, analysisApp: nil, now: 40)
    #expect(savedRoute.stopped && savedRoute.checks == 0)
    #expect(controller.errors.isEmpty && controller.routes.count == 1)
    idle.processes = [99]
    idle.playing = true
    controller.reconcile(
        apps: [idle, live], output: usb(), settings: settings, enabled: true, analysisApp: nil, now: 41)
    #expect(created.last?.processes == [99])
}

@Test func oneStalledRouteCannotDisableOtherAppsAndRetryIsBounded() {
    var created: [FakeRoute] = []
    let controller = RouteController { app, output, _ in
        let route = FakeRoute(app, output)
        route.stalled = app.id == "bad"
        created.append(route)
        return route
    }
    let apps = [
        AudioApplication(id: "bad", name: "Bad", processes: [1], playing: true),
        AudioApplication(id: "good", name: "Good", processes: [2], playing: true),
    ]
    let settings = ["bad": adjusted, "good": adjusted]
    for now in [0.0, 5, 6, 7, 12, 100] {
        controller.reconcile(apps: apps, output: usb(), settings: settings, enabled: true, analysisApp: nil, now: now)
    }
    #expect(created.count == 3)  // Good once, stalled app twice.
    #expect(Set(controller.routes.keys) == ["good"])
    #expect(created[0].stopped && created[2].stopped && !created[1].stopped)
    #expect(controller.errors.keys.sorted() == ["bad"])
    controller.resetFailures()
    controller.reconcile(apps: apps, output: usb(), settings: settings, enabled: true, analysisApp: nil, now: 101)
    #expect(created.count == 4 && controller.routes.count == 2)
}

@Test func routesFollowOutputAndCurrentProcessesAndGlobalBypassReleasesEverything() {
    var created: [FakeRoute] = []
    let controller = RouteController { app, output, _ in
        let route = FakeRoute(app, output)
        created.append(route)
        return route
    }
    var app = AudioApplication(id: "app", name: "App", processes: [1], playing: true, outputDevices: [99])
    controller.reconcile(
        apps: [app], output: usb(), settings: ["app": adjusted], enabled: true, analysisApp: nil, now: 0)
    #expect(created.isEmpty && controller.messages["app"] == "Playing on another output")
    app.outputDevices = [10]
    controller.reconcile(
        apps: [app], output: usb(), settings: ["app": adjusted], enabled: true, analysisApp: nil, now: 1)
    app.processes = [2]
    controller.reconcile(
        apps: [app], output: usb(), settings: ["app": adjusted], enabled: true, analysisApp: nil, now: 2)
    #expect(created.count == 2 && created[0].stopped && created[1].processes == [2])
    app.outputDevices = [11]
    controller.reconcile(
        apps: [app], output: usb(11), settings: ["app": adjusted], enabled: true, analysisApp: nil, now: 3)
    #expect(created.count == 3 && created[1].stopped && created[2].output.id == 11)
    controller.reconcile(
        apps: [app], output: usb(11), settings: ["app": adjusted], enabled: false, analysisApp: nil, now: 4)
    #expect(controller.routes.isEmpty && created[2].stopped)
}
