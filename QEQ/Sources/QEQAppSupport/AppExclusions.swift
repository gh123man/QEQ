import Combine
import Foundation

public struct ExcludedApp: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
public final class AppExclusions: ObservableObject {
    public static let initial = [ExcludedApp(id: "com.apple.PowerChime", name: "PowerChime")]
    @Published public private(set) var apps: [ExcludedApp]
    public var onChange: ((Set<String>) -> Void)?
    public var ids: Set<String> { Set(apps.map(\.id)) }
    private let defaults: UserDefaults?
    private static let key = "excludedApps"

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key),
            let saved = try? JSONDecoder().decode([ExcludedApp].self, from: data)
        {
            apps = saved
        } else {
            apps = Self.initial
        }
    }
    public func exclude(_ app: AudioApplication) {
        guard !ids.contains(app.id) else { return }
        apps.append(ExcludedApp(id: app.id, name: app.name))
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }
    public func remove(_ id: String) {
        apps.removeAll { $0.id == id }
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(apps) { defaults?.set(data, forKey: Self.key) }
        onChange?(ids)
    }
    nonisolated public static func contains(_ app: AudioApplication, ids: Set<String>) -> Bool {
        ids.contains(app.id) || !ids.isDisjoint(with: app.aliases)
    }
}
