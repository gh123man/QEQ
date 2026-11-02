import Foundation
import Testing

@testable import QEQAppSupport

private func release(_ version: String, prerelease: Bool = false, draft: Bool = false, complete: Bool = true)
    -> ReleaseChecker.Release
{
    .init(
        tagName: "v\(version)", draft: draft, prerelease: prerelease,
        assets: complete
            ? [
                .init(name: "appcast.xml", state: "uploaded", size: 500),
                .init(name: "QEQ-\(version)-macOS.zip", state: "uploaded", size: 1000),
            ] : [])
}

@Test func releaseVersionsOrderStableAndRCNumericallyAndRejectMalformedTags() {
    let values = ["0.1.0-rc.2", "0.1.0-rc.10", "0.1.0", "0.1.1-rc.1", "0.2.0", "1.0.0"]
    for pair in zip(values, values.dropFirst()) { #expect(ReleaseVersion(pair.0)! < ReleaseVersion(pair.1)!) }
    #expect(ReleaseVersion("v0.1.0") == ReleaseVersion("0.1.0"))
    for value in ["", "1.0", "01.0.0", "1.0.0-rc.0", "1.0.0-rc.-1", "1.0.0-beta.1", "1.0.0/evil", "1.0.0-rc.2x"] {
        #expect(ReleaseVersion(value) == nil)
    }
}

@Test func updateSelectionRequiresOptInAndCompletePublishedArtifacts() {
    let values = [
        release("0.1.0"), release("0.1.1-rc.2", prerelease: true),
        release("0.1.1-rc.10", prerelease: true), release("9.0.0", draft: true),
        release("8.0.0", complete: false), release("7.0.0", prerelease: true),
    ]
    #expect(ReleaseChecker.select(values, currentVersion: "0.1.0-rc.6", includeRC: false)?.version == "0.1.0")
    #expect(ReleaseChecker.select(values, currentVersion: "0.1.0-rc.6", includeRC: true)?.version == "0.1.1-rc.10")
    #expect(ReleaseChecker.select(values, currentVersion: "0.2.0", includeRC: true) == nil)
    #expect(ReleaseChecker.select(values, currentVersion: "invalid", includeRC: true) == nil)
    #expect(
        ReleaseChecker.select([release("0.1.0-rc.7", prerelease: true)], currentVersion: "0.1.0-rc.6", includeRC: false)
            == nil)
    let available = AvailableUpdate(version: "0.1.0-rc.7")
    #expect(
        available.feedURL.absoluteString == "https://github.com/gh123man/QEQ/releases/download/v0.1.0-rc.7/appcast.xml")
}

@Test func updateChecksAreDailyAndRecoverFromClockChanges() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(ReleaseChecker.isDue(lastCheck: nil, now: now))
    #expect(!ReleaseChecker.isDue(lastCheck: now.addingTimeInterval(-1000), now: now))
    #expect(ReleaseChecker.isDue(lastCheck: now.addingTimeInterval(-86400), now: now))
    #expect(ReleaseChecker.isDue(lastCheck: now.addingTimeInterval(10), now: now))
}

@MainActor private func waitForCheck(_ store: UpdateStore) async throws {
    for _ in 0..<100 {
        if !store.checking { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!store.checking)
}

@Test @MainActor func updateChecksNeverInstallAndChannelChangesDiscardPendingResults() async throws {
    let store = UpdateStore(
        currentVersion: "0.1.0", distribution: true, defaults: nil,
        checker: { _, _ in
            // Simulate a server response arriving after cancellation.
            try? await Task.sleep(for: .milliseconds(70))
            return AvailableUpdate(version: "0.2.0-rc.1")
        })
    var installs = 0
    store.installHandler = { _ in installs += 1 }
    store.setAutomatic(false)
    store.setIncludeRC(true)
    store.checkNow()
    try await waitForCheck(store)
    #expect(store.available?.version == "0.2.0-rc.1")
    #expect(installs == 0)
    store.install()
    #expect(installs == 1)
    store.installFinished(error: nil)
    store.checkNow()
    store.setIncludeRC(false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.available == nil)
    #expect(!store.checking)
    store.stop()
}

@Test @MainActor func updatePreferencesPersistAndFailedChecksDoNotClaimUpToDate() async throws {
    let name = "QEQ.updates.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = UpdateStore(
        currentVersion: "0.1.0", distribution: false, defaults: defaults,
        checker: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
    #expect(store.automatic && !store.includeRC)
    store.setAutomatic(false)
    store.setIncludeRC(true)
    store.checkNow()
    try await waitForCheck(store)
    #expect(store.lastCheck == nil)
    #expect(store.message.contains("Couldn’t"))
    let restored = UpdateStore(currentVersion: "0.1.0", distribution: false, defaults: defaults)
    #expect(!restored.automatic && restored.includeRC)
    store.stop()
    restored.stop()
}
