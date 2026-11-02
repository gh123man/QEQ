import CoreAudio
import Foundation
import QEQCore

protocol AudioRoute: AnyObject {
    var processes: [AudioObjectID] { get }
    var output: OutputDevice { get }
    var peak: Float { get }
    var lastFrames: UInt64 { get }
    func update(_ settings: MixerSettings, global: MixerSettings)
    func setAnalysis(_ enabled: Bool)
    func analysis(using analyzer: SpectrumAnalyzer) -> AudioTelemetry?
    func checkHealth() throws
    func stop()
}

/// All access is on the engine control queue. Saved UI rows are not capture targets:
/// only clients actively playing to the selected output may acquire a route.
final class RouteController {
    private(set) var routes: [String: any AudioRoute] = [:]
    private(set) var messages: [String: String] = [:]
    private(set) var errors: [String: String] = [:]
    private struct Retry {
        let processes: [AudioObjectID]
        let output: OutputDevice
        let after: TimeInterval
        let attempts: Int
        let message: String
    }
    private var retries: [String: Retry] = [:]
    private let log: AppLog?
    private let create: (AudioApplication, OutputDevice, MixerSettings, MixerSettings) throws -> any AudioRoute
    init(
        log: AppLog? = nil,
        create: @escaping (AudioApplication, OutputDevice, MixerSettings, MixerSettings) throws -> any AudioRoute = {
            try AppAudioRoute(app: $0, output: $1, settings: $2, global: $3)
        }
    ) {
        self.create = create
        self.log = log
    }

    func resetFailures() {
        retries.removeAll()
        errors.removeAll()
        messages.removeAll()
    }
    func stop() {
        if !routes.isEmpty { log?.write(.info, "Releasing all audio routes (\(routes.count))") }
        for route in routes.values { route.stop() }
        routes.removeAll()
        resetFailures()
    }
    func remove(_ id: String) {
        if routes[id] != nil { log?.write(.info, "Releasing audio route: \(id)") }
        routes.removeValue(forKey: id)?.stop()
        retries.removeValue(forKey: id)
    }

    func reconcile(
        apps: [AudioApplication], output: OutputDevice, settings: [String: MixerSettings],
        enabled: Bool, analysisApp: String?, now: TimeInterval,
        shouldContinue: () -> Bool = { true }, global: MixerSettings = MixerSettings(), analyzeAll: Bool = false
    ) {
        messages.removeAll()
        errors.removeAll()
        guard enabled else {
            stop()
            return
        }
        var wanted: [String: AudioApplication] = [:]
        for app in apps {
            let value = settings[app.id] ?? MixerSettings()
            let analyzing =
                analyzeAll || analysisApp == MixerEngine.globalEQID || (app.id == analysisApp && value.enabled)
            guard value.needsProcessing || global.hasEnabledEQ || analyzing else { continue }
            guard app.playing, !app.processes.isEmpty else {
                messages[app.id] = "Waiting for playback"
                continue
            }
            if let devices = app.outputDevices, !devices.contains(output.id) {
                messages[app.id] = "Playing on another output"
                continue
            }
            wanted[app.id] = app
        }
        for id in Array(routes.keys) {
            guard let route = routes[id] else { continue }
            if wanted[id]?.processes != route.processes || route.output != output {
                remove(id)
            }
        }
        retries = retries.filter { id, retry in wanted[id]?.processes == retry.processes && retry.output == output }
        for app in wanted.values.sorted(by: { $0.id < $1.id }) {
            guard shouldContinue() else {
                stop()
                return
            }
            if let route = routes[app.id] {
                route.setAnalysis(analyzeAll || app.id == analysisApp || analysisApp == MixerEngine.globalEQID)
                do {
                    try route.checkHealth()
                    continue
                } catch {
                    fail(app: app, output: output, now: now, error: error)
                    continue
                }
            }
            if let retry = retries[app.id], now < retry.after {
                messages[app.id] = retry.message
                errors[app.id] = retry.message
                continue
            }
            do {
                let route = try create(app, output, settings[app.id] ?? MixerSettings(), global)
                route.setAnalysis(analyzeAll || app.id == analysisApp || analysisApp == MixerEngine.globalEQID)
                routes[app.id] = route
                log?.write(
                    .info,
                    "Audio route started: \(app.id), output=\(output.name), \(output.sampleRate) Hz, \(output.bufferFrames) frames"
                )
                // Keep attempt count until this route has actually delivered audio.
            } catch { fail(app: app, output: output, now: now, error: error) }
        }
        for (id, route) in routes where route.lastFrames > 0 { retries.removeValue(forKey: id) }
    }
    private func fail(app: AudioApplication, output: OutputDevice, now: TimeInterval, error: Error) {
        routes.removeValue(forKey: app.id)?.stop()
        let attempts = (retries[app.id]?.attempts ?? 0) + 1
        // One automatic fresh route; after that wait for Retry, playback restart,
        // a new process, or an output change instead of repeatedly interrupting audio.
        let retrying = attempts < 2
        let message =
            "\(app.name) on \(output.name): \(error.localizedDescription) "
            + (retrying ? "Reconnecting this app…" : "This app is bypassed. Retry after checking its output.")
        log?.write(.warning, message)
        retries[app.id] = Retry(
            processes: app.processes, output: output, after: retrying ? now + 2 : .infinity,
            attempts: attempts, message: message)
        messages[app.id] = message
        errors[app.id] = message
    }
}
