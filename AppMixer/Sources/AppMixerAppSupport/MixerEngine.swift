import AppMixerCore
import Foundation
import os

public struct MixerSnapshot: Sendable {
    public var apps: [AudioApplication] = []
    public var active: Set<String> = []
    public var peaks: [String: Float] = [:]
    public var outputName = "System output"
    public var timing = ""
    public var sampleRate: Double = 48000
    public var error: String?
    public var enabled = false
    public var migratedIDs: [String: String] = [:]
    public init() {}
}

// All mutable engine state and route lifetimes are confined to queue.
public final class MixerEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.AppMixer.engine", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var analysisTimer: DispatchSourceTimer?
    private var analysisApp: String?
    private let analyzer = SpectrumAnalyzer()
    private var deliverAnalysis: (@Sendable (AudioTelemetry) -> Void)?
    private var routes: [String: AppAudioRoute] = [:]
    private var settings: [String: MixerSettings] = [:]
    private var appList = AudioAppList()
    private var enabled = false
    private let requestedEnabled = OSAllocatedUnfairLock(initialState: false)
    private var suspended = false
    private var failure: String?
    private var deliver: (@Sendable (MixerSnapshot) -> Void)?
    public init() {}
    public func start(settings: [String: MixerSettings], deliver: @escaping @Sendable (MixerSnapshot) -> Void) {
        queue.async { [self] in
            self.settings = settings
            self.deliver = deliver
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()
        }
    }
    public func setEnabled(_ value: Bool) {
        requestedEnabled.withLock { $0 = value }
        queue.async { [self] in
            enabled = requestedEnabled.withLock { $0 }
            failure = nil
            if !value { stopRoutes() }
            refresh()
        }
    }
    public func update(_ key: String, settings value: MixerSettings) {
        queue.async { [self] in
            let value = value.sanitized()
            settings[key] = value
            if !value.needsProcessing {
                routes.removeValue(forKey: key)?.stop()
            } else if let route = routes[key] {
                route.update(value)
            }
            // New routes are created at the next discovery tick, so slider drags don't queue HAL calls.
        }
    }
    public func setAnalysisApp(_ key: String?, deliver: @escaping @Sendable (AudioTelemetry) -> Void) {
        queue.async { [self] in
            analysisApp = key
            deliverAnalysis = deliver
            analyzer.reset()
            analysisTimer?.cancel()
            analysisTimer = nil
            for (id, route) in routes { route.setAnalysis(id == key) }
            deliver(AudioTelemetry())
            guard key != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(67), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, let key = analysisApp else { return }
                guard let route = routes[key] else {
                    deliverAnalysis?(AudioTelemetry())
                    return
                }
                if let value = route.analysis(using: analyzer) { deliverAnalysis?(value) }
            }
            analysisTimer = timer
            timer.resume()
        }
    }
    public func suspend(_ value: Bool) {
        queue.async { [self] in
            suspended = value
            if value { stopRoutes() }
            refresh()
        }
    }
    public func shutdown() {
        requestedEnabled.withLock { $0 = false }
        queue.sync {
            timer?.cancel()
            timer = nil
            analysisTimer?.cancel()
            analysisTimer = nil
            enabled = false
            stopRoutes()
            deliver = nil
        }
    }
    private func stopRoutes() {
        for route in routes.values { route.stop() }
        routes.removeAll()
    }
    private func refresh() {
        var snapshot = MixerSnapshot()
        enabled = enabled && requestedEnabled.withLock { $0 }
        do {
            let discovered = try HAL.applications()
            for app in discovered {
                for alias in app.aliases.sorted() where settings[alias] != nil {
                    if settings[app.id] == nil { settings[app.id] = settings[alias] }
                    settings.removeValue(forKey: alias)
                    snapshot.migratedIDs[alias] = app.id
                }
            }
            snapshot.apps = appList.visibleApps(from: discovered, settings: settings)
            let output = try HAL.output()
            snapshot.outputName = output.name
            snapshot.sampleRate = output.sampleRate
            snapshot.timing = String(
                format: "%d frames · %.1f ms I/O buffer · %.0f kHz", output.bufferFrames,
                Double(output.bufferFrames) / output.sampleRate * 1000, output.sampleRate / 1000)
            let wanted = Dictionary(
                uniqueKeysWithValues: discovered.filter { (settings[$0.id] ?? MixerSettings()).needsProcessing }.map {
                    ($0.id, $0)
                })
            for key in Array(routes.keys) {
                guard let route = routes[key] else { continue }
                if !enabled || suspended || wanted[key]?.processes != route.processes || output != route.output {
                    routes.removeValue(forKey: key)?.stop()
                } else {
                    try route.checkHealth()
                }
            }
            if enabled && !suspended {
                for app in wanted.values where routes[app.id] == nil {
                    guard requestedEnabled.withLock({ $0 }) else { break }
                    routes[app.id] = try AppAudioRoute(
                        app: app, output: output, settings: settings[app.id] ?? MixerSettings())
                    routes[app.id]?.setAnalysis(app.id == analysisApp)
                }
            }
            if !requestedEnabled.withLock({ $0 }) {
                enabled = false
                stopRoutes()
            }
            snapshot.active = Set(routes.keys)
            snapshot.peaks = routes.mapValues { $0.peak }
        } catch {
            failure = error.localizedDescription
            enabled = false
            requestedEnabled.withLock { $0 = false }
            stopRoutes()
        }
        snapshot.enabled = enabled
        snapshot.error = failure
        deliver?(snapshot)
    }
}
