import Foundation
import Testing

@testable import QEQAppSupport

@Test @MainActor func exclusionsPersistIncludingAnExplicitlyEmptyList() {
    let name = "QEQ.exclusions.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppExclusions(defaults: defaults)
    #expect(store.ids == ["com.apple.PowerChime"])
    store.remove("com.apple.PowerChime")
    #expect(AppExclusions(defaults: defaults).apps.isEmpty)
    let app = AudioApplication(id: "com.example.music", name: "Music")
    var changed: Set<String> = []
    store.onChange = { changed = $0 }
    store.exclude(app)
    store.exclude(app)
    #expect(store.apps.count == 1 && changed == [app.id])
    #expect(AppExclusions(defaults: defaults).apps == store.apps)
    #expect(!AppExclusions.contains(AudioApplication(id: "different", name: "PowerChime"), ids: store.ids))
    #expect(AppExclusions.contains(AudioApplication(id: "parent", name: "Music", aliases: [app.id]), ids: store.ids))
}
