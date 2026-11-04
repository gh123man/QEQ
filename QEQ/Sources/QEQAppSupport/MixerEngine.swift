import Foundation
import QEQCore
import os

public struct MixerSnapshot: Equatable, Sendable {
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
    private var lastAnalysis = AudioTelemetry()
    private var deliverAnalysis: (@Sendable (AudioTelemetry) -> Void)?
    private let controller: RouteController
    private let discover: (() throws -> [AudioApplication])?
    private let readOutput: () throws -> OutputDevice
    private var discoveryInterval: TimeInterval = 1
    private var settings: [String: MixerSettings] = [:]
    private var globalEQ = MixerSettings()
    private var appList = AudioAppList()
    private var excludedIDs: Set<String> = []
    private let identityCache = AppIdentityCache()
    private var enabled = false
    private let requestedEnabled = OSAllocatedUnfairLock(initialState: false)
    private var suspended = false
    private var failure: String?
    private var lastLoggedFailure: String?
    private var logging = true
    private var deliver: (@Sendable (MixerSnapshot) -> Void)?
    public init() {
        controller = RouteController(log: .shared)
        discover = nil
        readOutput = { try HAL.output() }
    }
    init(
        controller: RouteController, discover: @escaping () throws -> [AudioApplication],
        readOutput: @escaping () throws -> OutputDevice, discoveryInterval: TimeInterval = 1
    ) {
        logging = false
        self.controller = controller
        self.discover = discover
        self.readOutput = readOutput
        self.discoveryInterval = discoveryInterval
    }
    public func start(
        settings: [String: MixerSettings], global: MixerSettings = MixerSettings(),
        enabled initialEnabled: Bool = false,
        excludedIDs: Set<String> = [],
        deliver: @escaping @Sendable (MixerSnapshot) -> Void
    ) {
        requestedEnabled.withLock { $0 = initialEnabled }
        queue.async { [self] in
            self.settings = settings
            self.excludedIDs = excludedIDs
            self.globalEQ = global
            self.enabled = requestedEnabled.withLock { $0 }
            self.deliver = deliver
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: discoveryInterval, leeway: .milliseconds(200))
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
    public func setExcludedApps(_ ids: Set<String>) {
        queue.async { [self] in
            excludedIDs = ids
            refresh()
            if analysisApp != nil { readAnalysis() }
        }
    }
    public func update(_ key: String, settings value: MixerSettings) {
        queue.async { [self] in
            let value = value.sanitized()
            settings[key] = value
            if let route = controller.routes[key] {
                route.update(value, global: globalEQ)
            }
            // Settings change coefficients, never route lifetime. Discovery owns topology.
        }
    }
    public func setGlobalEQ(_ value: MixerSettings) {
        queue.async { [self] in
            globalEQ = value.sanitized()
            for (id, route) in controller.routes {
                route.update(settings[id] ?? MixerSettings(), global: globalEQ)
            }
            // Changing filters does not create or destroy audio routes.
        }
    }
    public func setAnalysisApp(
        _ key: String?, includeGlobal: Bool = false, deliver: @escaping @Sendable (AudioTelemetry) -> Void
    ) {
        queue.async { [self] in
            analysisApp = key
            analyzeAll = includeGlobal
            deliverAnalysis = deliver
            analysisReadings.removeAll()
            lastAnalysis = AudioTelemetry()
            deliver(lastAnalysis)
            // Presentation only subscribes/unsubscribes to existing snapshots.
            // No discovery, health checks, DSP configuration, or HAL lifecycle here.
            refreshAnalysisTimer()
            if key != nil { readAnalysis() }
        }
    }
    /// Only wake at visual frame rate while a visible spectrum has an audio route.
    /// Discovery still runs once per second so playback/recovery remain responsive.
    private func refreshAnalysisTimer() {
        // Reuse FFT plans across openings, but release them with their audio route.
        analyzers = analyzers.filter { controller.routes[$0.key] != nil }
        analysisReadings = analysisReadings.filter { controller.routes[$0.key] != nil }
        guard let key = analysisApp,
            controller.routes.keys.contains(where: { analyzeAll || key == Self.globalEQID || $0 == key })
        else {
            analysisTimer?.cancel()
            analysisTimer = nil
            analysisReadings.removeAll()
            publishAnalysis(AudioTelemetry())
            return
        }
        guard analysisTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Match the short trace interpolation so fresh measurements arrive without
        // a stationary gap between animations. This timer stops with the panel.
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.readAnalysis() }
        analysisTimer = timer
        timer.resume()
    }
    private func readAnalysis() {
        guard let key = analysisApp else { return }
        let routes = controller.routes.filter { analyzeAll || key == Self.globalEQID || $0.key == key }
        analyzers = analyzers.filter { controller.routes[$0.key] != nil }
        analysisReadings = analysisReadings.filter { routes[$0.key] != nil }
        for (id, route) in routes {
            let analyzer = analyzers[id] ?? SpectrumAnalyzer()
            analyzers[id] = analyzer
            if let value = route.analysis(using: analyzer) { analysisReadings[id] = value }
            // Meters do not wait for a full FFT window or a successful snapshot.
            var reading = analysisReadings[id] ?? AudioTelemetry()
            reading.peak = route.peak
            reading.sourcePeak = route.sourcePeak
            analysisReadings[id] = reading
        }
        var combined = AudioTelemetry.envelope(Array(analysisReadings.values))
        combined.apps = analysisReadings
        publishAnalysis(combined)
    }
    private func publishAnalysis(_ value: AudioTelemetry) {
        guard value != lastAnalysis else { return }
        lastAnalysis = value
        deliverAnalysis?(value)
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
        analyzers.removeAll()
        analysisReadings.removeAll()
    }
    private func refresh() {
        var snapshot = MixerSnapshot()
        enabled = enabled && requestedEnabled.withLock { $0 }
        do {
            let allApps = try discover?() ?? HAL.applications(identityCache: identityCache)
            let discovered = allApps.filter { !AppExclusions.contains($0, ids: excludedIDs) }
            for app in discovered {
                for alias in app.aliases.sorted() where settings[alias] != nil {
                    if settings[app.id] == nil { settings[app.id] = settings[alias] }
                    settings.removeValue(forKey: alias)
                    snapshot.migratedIDs[alias] = app.id
                }
            }
            snapshot.apps = appList.visibleApps(from: discovered, settings: settings)
            let output = try readOutput()
            snapshot.outputName = output.name
            snapshot.sampleRate = output.sampleRate
            snapshot.timing = String(
                format: "%d frames · %.1f ms I/O buffer · %.0f kHz", output.bufferFrames,
                Double(output.bufferFrames) / output.sampleRate * 1000, output.sampleRate / 1000)
            controller.reconcile(
                apps: discovered, output: output, settings: settings,
                enabled: enabled && !suspended,
                now: ProcessInfo.processInfo.systemUptime,
                shouldContinue: { self.requestedEnabled.withLock { $0 } }, global: globalEQ)
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
            if logging, failure != lastLoggedFailure {
                AppLog.shared.write(.error, "Audio discovery failed: \(error.localizedDescription)")
                lastLoggedFailure = failure
            }
            enabled = false
            requestedEnabled.withLock { $0 = false }
            stopRoutes()
        }
        if logging {
            AppLog.shared.write(
                .debug,
                "Audio state: enabled=\(enabled), output=\(snapshot.outputName), active=\(snapshot.active.sorted()), callbackFrames=\(snapshot.callbackFrames), peaks=\(snapshot.peaks)"
            )
        }
        snapshot.enabled = enabled
        snapshot.error = failure ?? snapshot.error
        refreshAnalysisTimer()
        deliver?(snapshot)
    }
}
