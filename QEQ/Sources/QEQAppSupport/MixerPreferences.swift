import Foundation

public struct MixerPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var enabled: Bool {
        get { defaults.object(forKey: "mixerEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "mixerEnabled") }
    }
}
