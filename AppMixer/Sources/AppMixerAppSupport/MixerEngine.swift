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
    public var routeMessages: [String: String] = [:]
    public var callbackFrames: [String: UInt64] = [:]
    public var error: String?
    public var enabled = false
    public var migratedIDs: [String: String] = [:]
    public init() {}
}

// All mutable engine state and route lifetimes are confined to queue.
public final class MixerEngine: @unchecked Sendable {
    public static let globalEQID = "__qeq_global_eq__"
    private let queue = DispatchQueue(label: "local.AppMixer.engine", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var analysisTimer: DispatchSourceTimer?
    private var analysisApp: String?
    private var analyzeAll = false
    private var analyzers: [String: SpectrumAnalyzer] = [:]
    private var analysisReadings: [String: AudioTelemetry] = [:]
    private var deliverAnalysis: (@Sendable (AudioTelemetry) -> Void)?
    private let controller = RouteController()
    private var settings: [String: MixerSettings] = [:]
    private var globalEQ = MixerSettings()
    private var appList = AudioAppList()
    private var enabled = false
    private let requestedEnabled = OSAllocatedUnfairLock(initialState: false)
    private var suspended = false
    private var failure: String?
    private var deliver: (@Sendable (MixerSnapshot) -> Void)?
    public init() {}
    public func start(
        settings: [String: MixerSettings], global: MixerSettings = MixerSettings(),
        enabled initialEnabled: Bool = false,
        deliver: @escaping @Sendable (MixerSnapshot) -> Void
    ) {
        requestedEnabled.withLock { $0 = initialEnabled }
        queue.async { [self] in
            self.settings = settings
            self.globalEQ = global
            self.enabled = requestedEnabled.withLock { $0 }
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
            controller.resetFailures()
            if !value { stopRoutes() }
            refresh()
        }
    }
    public func update(_ key: String, settings value: MixerSettings) {
        queue.async { [self] in
            let value = value.sanitized()
            settings[key] = value
            let analyzing = analyzeAll || analysisApp == Self.globalEQID || (key == analysisApp && value.enabled)
            if !value.needsProcessing && !globalEQ.hasEnabledEQ && !analyzing {
                controller.remove(key)
            } else if let route = controller.routes[key] {
                route.update(value, global: globalEQ)
            }
            // New routes are created at the next discovery tick, so slider drags don't queue HAL calls.
        }
    }
    public func setGlobalEQ(_ value: MixerSettings) {
        queue.async { [self] in
            globalEQ = value.sanitized()
            for (id, route) in controller.routes {
                route.update(settings[id] ?? MixerSettings(), global: globalEQ)
            }
            // Discovery creates/removes routes on its next tick, not on each drag.
        }
    }
    public func setAnalysisApp(
        _ key: String?, includeGlobal: Bool = false, deliver: @escaping @Sendable (AudioTelemetry) -> Void
    ) {
        queue.async { [self] in
            analysisApp = key
            analyzeAll = includeGlobal
            deliverAnalysis = deliver
            analyzers.removeAll()
            analysisReadings.removeAll()
            analysisTimer?.cancel()
            analysisTimer = nil
            for (id, route) in controller.routes {
                route.setAnalysis(analyzeAll || id == key || key == Self.globalEQID)
            }
            deliver(AudioTelemetry())
            // Opening a flat EQ needs a route for its spectrum too. Closing the
            // panel releases that route immediately unless its audio is adjusted.
            refresh()
            guard key != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(67), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, let key = analysisApp else { return }
                let routes = controller.routes.filter { analyzeAll || key == Self.globalEQID || $0.key == key }
                analyzers = analyzers.filter { routes[$0.key] != nil }
                analysisReadings = analysisReadings.filter { routes[$0.key] != nil }
                for (id, route) in routes {
                    let analyzer = analyzers[id] ?? SpectrumAnalyzer()
                    analyzers[id] = analyzer
                    if let value = route.analysis(using: analyzer) { analysisReadings[id] = value }
                    // Level meters should not wait for a full FFT window or a
                    // successful spectrum snapshot while its writer is active.
                    var reading = analysisReadings[id] ?? AudioTelemetry()
                    reading.peak = route.peak
                    analysisReadings[id] = reading
                }
                var combined = AudioTelemetry.envelope(Array(analysisReadings.values))
                combined.apps = analysisReadings
                deliverAnalysis?(combined)
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
        controller.stop()
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
            controller.reconcile(
                apps: discovered, output: output, settings: settings,
                enabled: enabled && !suspended, analysisApp: analysisApp,
                now: ProcessInfo.processInfo.systemUptime,
                shouldContinue: { self.requestedEnabled.withLock { $0 } }, global: globalEQ, analyzeAll: analyzeAll)
            if !requestedEnabled.withLock({ $0 }) {
                enabled = false
                stopRoutes()
            }
            snapshot.active = Set(controller.routes.keys)
            snapshot.peaks = controller.routes.mapValues { $0.peak }
            snapshot.callbackFrames = controller.routes.mapValues { $0.lastFrames }
            snapshot.routeMessages = controller.messages
            snapshot.error = controller.errors.keys.sorted().first.flatMap { controller.errors[$0] }
        } catch {
            failure = error.localizedDescription
            enabled = false
            requestedEnabled.withLock { $0 = false }
            stopRoutes()
        }
        snapshot.enabled = enabled
        snapshot.error = failure ?? snapshot.error
        deliver?(snapshot)
    }
}
