import QEQCore

/// Audio-client registration alone doesn't mean an app has ever played sound.
/// Remember observed output activity while its clients exist so pausing playback
/// doesn't remove the controls. Never retain stale Core Audio process IDs.
struct AudioAppList {
    private var heardApps: Set<String> = []

    mutating func visibleApps(from discovered: [AudioApplication], settings: [String: MixerSettings])
        -> [AudioApplication]
    {
        heardApps.formIntersection(discovered.map(\.id))
        heardApps.formUnion(discovered.filter(\.playing).map(\.id))
        return discovered.filter {
            heardApps.contains($0.id) || (settings[$0.id] ?? MixerSettings()).shouldPersist
        }
    }
}
