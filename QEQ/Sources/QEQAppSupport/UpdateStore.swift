import Combine
import Foundation

/// Quiet release discovery is separate from the installer: checking never opens UI.
@MainActor
public final class UpdateStore: ObservableObject {
    @Published public private(set) var automatic: Bool
    @Published public private(set) var includeRC: Bool
    @Published public private(set) var available: AvailableUpdate?
    @Published public private(set) var checking = false
    @Published public private(set) var installing = false
    @Published public private(set) var message = "Not checked yet."
    @Published public private(set) var lastCheck: Date?
    public let currentVersion: String
    public let distribution: Bool
    public var installHandler: (@MainActor (AvailableUpdate) -> Void)?
    private let defaults: UserDefaults?
    private let logger: AppLog?
    private let checker: @Sendable (String, Bool) async throws -> AvailableUpdate?
    private var request: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt: Date?

    public init(
        currentVersion: String, distribution: Bool, defaults: UserDefaults? = .standard,
        logger: AppLog? = nil, previewUpdate: AvailableUpdate? = nil,
        checker: @escaping @Sendable (String, Bool) async throws -> AvailableUpdate? = {
            try await ReleaseChecker().check(currentVersion: $0, includeRC: $1)
        }
    ) {
        self.currentVersion = currentVersion
        self.distribution = distribution
        self.defaults = defaults
        self.logger = logger
        self.checker = checker
        automatic = defaults?.object(forKey: "updates.automatic") as? Bool ?? true
        includeRC = defaults?.bool(forKey: "updates.includeRC") ?? false
        lastAttempt = defaults?.object(forKey: "updates.lastAttempt") as? Date
        lastCheck = defaults?.object(forKey: "updates.lastCheck") as? Date
        if let cached = defaults?.string(forKey: "updates.availableVersion"),
            let version = ReleaseVersion(cached), let current = ReleaseVersion(currentVersion), version > current,
            version.rc == nil || includeRC
        {
            available = AvailableUpdate(version: cached)
        }
        if defaults == nil { available = previewUpdate }
        if let available { message = "Version \(available.version) is available." }
    }
    public func start() {
        schedule?.cancel()
        guard automatic, distribution else { return }
        schedule = Task { [weak self] in
            do {
                // Avoid launch/audio-route setup; no frequent idle polling.
                try await Task.sleep(for: .seconds(15))
                while let self, !Task.isCancelled, self.automatic {
                    if ReleaseChecker.isDue(lastCheck: self.lastAttempt) { self.checkNow() }
                    let elapsed = self.lastAttempt.map { Date().timeIntervalSince($0) } ?? 0
                    try await Task.sleep(for: .seconds(max(60, ReleaseChecker.interval - elapsed)))
                }
            } catch {
                // A preference change or shutdown cancels the timer.
            }
        }
    }
    public func stop() {
        schedule?.cancel()
        schedule = nil
        cancelCheck()
    }
    public func setAutomatic(_ value: Bool) {
        automatic = value
        defaults?.set(value, forKey: "updates.automatic")
        if !value { cancelCheck() }
        start()
    }
    public func setIncludeRC(_ value: Bool) {
        guard !installing else { return }
        cancelCheck()
        includeRC = value
        defaults?.set(value, forKey: "updates.includeRC")
        available = nil
        defaults?.removeObject(forKey: "updates.availableVersion")
        lastAttempt = nil
        defaults?.removeObject(forKey: "updates.lastAttempt")
        message = "Update channel changed."
        start()
        if automatic && distribution { checkNow() }
    }
    private func cancelCheck() {
        generation += 1
        request?.cancel()
        request = nil
        checking = false
    }
    public func checkNow() {
        guard !checking, !installing else { return }
        checking = true
        message = "Checking…"
        lastAttempt = Date()
        defaults?.set(lastAttempt, forKey: "updates.lastAttempt")
        let generation = generation
        let version = currentVersion
        let includeRC = includeRC
        request = Task { [weak self, checker] in
            do {
                let result = try await checker(version, includeRC)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.available = result
                self.defaults?.set(result?.version, forKey: "updates.availableVersion")
                self.lastCheck = Date()
                self.defaults?.set(self.lastCheck, forKey: "updates.lastCheck")
                self.message =
                    result.map { "Version \($0.version) is available." }
                    ?? (includeRC ? "No newer release available." : "No newer stable release available.")
                self.logger?.write(.info, "Update check: \(self.message)")
                self.checking = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.message = "Couldn’t check for updates. Try again later."
                self.logger?.write(.warning, "Update check failed: \(error.localizedDescription)")
                self.checking = false
            }
        }
    }
    public func install() {
        guard let available, !installing else { return }
        guard let installHandler else {
            message = "The updater is unavailable. Restart QEQ and try again."
            return
        }
        installing = true
        message = "Opening updater…"
        installHandler(available)
    }
    public func installStatus(_ value: String) { message = value }
    public func installFinished(error: Error?) {
        installing = false
        if let error {
            message = error.localizedDescription
            logger?.write(.warning, "Updater: \(error.localizedDescription)")
        } else {
            message = "Updater closed."
        }
    }
}
