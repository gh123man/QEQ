import Foundation
import ServiceManagement
import Testing

@testable import QEQAppSupport

@Test @MainActor func loginDefaultAppliesOnceAndRespectsSystemChanges() {
    let name = "QEQ.login.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    var status = SMAppService.Status.notRegistered
    var registrations = 0
    let store = LoginItemStore(
        defaults: defaults, readStatus: { status },
        register: {
            registrations += 1
            status = .enabled
        },
        unregister: { status = .notRegistered })
    store.start()
    #expect(store.enabled && registrations == 1)
    store.setEnabled(false)
    store.start()
    #expect(!store.enabled && registrations == 1)
    store.setEnabled(true)
    #expect(store.enabled && registrations == 2)
    // A user disables it externally; relaunch must not re-register it.
    status = .notRegistered
    let relaunched = LoginItemStore(
        defaults: defaults, readStatus: { status },
        register: { registrations += 1 }, unregister: {})
    relaunched.start()
    #expect(!relaunched.enabled && registrations == 2)
}

@Test @MainActor func loginApprovalAndFailureReflectActualSystemState() {
    let name = "QEQ.login.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    var status = SMAppService.Status.requiresApproval
    var attempts = 0
    let store = LoginItemStore(
        defaults: defaults, readStatus: { status },
        register: {
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        },
        unregister: { status = .notRegistered })
    store.start()
    #expect(store.enabled && store.requiresApproval && attempts == 0)
    store.setEnabled(false)
    #expect(!store.enabled)
    store.setEnabled(true)
    #expect(!store.enabled && store.error != nil && attempts == 1)
    store.start()
    #expect(attempts == 1)
    status = .enabled
    store.refresh()
    #expect(store.enabled && !store.requiresApproval)
}
