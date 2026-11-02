import Combine
import Foundation
import ServiceManagement

/// macOS owns the actual state. Apply the default once, never overriding a later
/// change made in QEQ or System Settings.
@MainActor
public final class LoginItemStore: ObservableObject {
    @Published public private(set) var status: SMAppService.Status
    @Published public private(set) var error: String?
    public var enabled: Bool { status == .enabled || status == .requiresApproval }
    public var requiresApproval: Bool { status == .requiresApproval }
    private let defaults: UserDefaults?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private static let initializedKey = "loginItem.initialized"

    public init(
        defaults: UserDefaults? = .standard,
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.defaults = defaults
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    public static func preview() -> LoginItemStore {
        LoginItemStore(defaults: nil, readStatus: { .enabled }, register: {}, unregister: {})
    }

    public func start() {
        refresh()
        guard let defaults, !defaults.bool(forKey: Self.initializedKey) else { return }
        // Mark before attempting registration so failures/denials do not prompt
        // again on every launch. The toggle allows an explicit retry.
        defaults.set(true, forKey: Self.initializedKey)
        if !enabled { setEnabled(true) }
    }

    public func refresh() { status = readStatus() }

    public func setEnabled(_ value: Bool) {
        defaults?.set(true, forKey: Self.initializedKey)
        error = nil
        refresh()
        do {
            if value && !enabled { try register() }
            if !value && enabled { try unregister() }
        } catch {
            self.error = "Couldn’t change startup: \(error.localizedDescription)"
        }
        refresh()
    }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
