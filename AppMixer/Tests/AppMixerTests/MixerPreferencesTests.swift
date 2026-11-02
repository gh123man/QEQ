import Foundation
import Testing

@testable import AppMixerAppSupport

@Test func firstLaunchEnabledPreferencePreservesExplicitBypassAcrossRelaunches() {
    let suite = "QEQ.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = MixerPreferences(defaults: defaults)
    #expect(preferences.enabled)
    preferences.enabled = false
    #expect(!MixerPreferences(defaults: UserDefaults(suiteName: suite)!).enabled)
    preferences.enabled = true
    #expect(MixerPreferences(defaults: UserDefaults(suiteName: suite)!).enabled)
}
