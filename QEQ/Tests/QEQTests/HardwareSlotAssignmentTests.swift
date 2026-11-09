import Foundation
import QEQAppSupport
import Testing

@Test @MainActor func hardwareSlotsSurviveAppAbsenceAndStoreReload() throws {
    let suite = "QEQ-slot-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HardwareSlotAssignments(defaults: defaults)
    store.assign(appID: "com.spotify.client", appName: "Spotify", serial: "board", number: 3)
    store.assign(appID: "com.browser", appName: "Browser", serial: "board", number: 1)
    // A fresh store has no running-app snapshot; ownership must still be intact.
    let reloaded = HardwareSlotAssignments(defaults: defaults)
    #expect(reloaded.slots(serial: "board", count: 4).map(\.appID) == ["com.browser", nil, "com.spotify.client", nil])
    #expect(reloaded.slots(serial: "board", count: 4)[2].appName == "Spotify")
    // Reassignment changes only the chosen slot and the same app's old slot.
    reloaded.assign(appID: "com.spotify.client", appName: "Spotify", serial: "board", number: 1)
    #expect(store.slots(serial: "board", count: 4).map(\.appID) == ["com.spotify.client", nil, nil, nil])
    store.assign(appID: "other", appName: "Other", serial: "second-board", number: 1)
    #expect(store.slots(serial: "board", count: 4)[0].appID == "com.spotify.client")
    #expect(store.slots(serial: "second-board", count: 4)[0].appID == "other")
}

@Test @MainActor func assigningAnotherSlotPreservesLegacyFirstSlot() throws {
    let suite = "QEQ-slot-migration-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("old-app", forKey: "hardwareTarget.board")
    let store = HardwareSlotAssignments(defaults: defaults)
    store.assign(appID: "new-app", appName: "New app", serial: "board", number: 4)
    #expect(store.slots(serial: "board", count: 4).map(\.appID) == ["old-app", nil, nil, "new-app"])
    #expect(defaults.string(forKey: "hardwareTarget.board") == nil)
    store.assign(appID: "old-app", appName: "Old app", serial: "board", number: 2)
    #expect(store.slots(serial: "board", count: 4).map(\.appID) == [nil, "old-app", nil, "new-app"])
    store.assign(appID: "bad", appName: "Bad", serial: "board", number: 5)
    #expect(store.slots(serial: "board", count: 4)[3].appID == "new-app")
}

@Test @MainActor func retainedAssignmentsPersistMetadataAndCanBeUnassignedOffline() throws {
    let suite = "QEQ-retained-slot-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HardwareSlotAssignments(defaults: defaults)
    store.assign(appID: "music", appName: "Music", serial: "board", number: 2, appPath: "/Applications/Music.app")
    store.assign(appID: "music", appName: "Music", serial: "other", number: 1, appPath: "/Applications/Music.app")
    store.assign(appID: "browser", appName: "Browser", serial: "other", number: 4)
    let reloaded = HardwareSlotAssignments(defaults: defaults)
    let apps = HardwareSlotAssignments.retainedApplications(from: reloaded.allAssignedSlots())
    #expect(apps.map(\.id) == ["browser", "music"])
    #expect(apps.last?.path == "/Applications/Music.app")
    #expect(apps.allSatisfy { !$0.playing && $0.processes.isEmpty })
    reloaded.unassign(appID: "music")
    #expect(store.allAssignedSlots().map(\.appID) == ["browser"])
    #expect(HardwareSlotAssignments.retainedApplications(from: store.allAssignedSlots()).map(\.id) == ["browser"])
    defaults.set("legacy", forKey: "hardwareTarget.oldboard")
    #expect(store.allAssignedSlots().contains { $0.appID == "legacy" })
    store.unassign(appID: "legacy")
    #expect(!store.allAssignedSlots().contains { $0.appID == "legacy" })
}
