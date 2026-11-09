import QEQCore

/// Audio-client registration alone doesn't mean an app has ever played sound.
/// Remember observed output activity while its clients exist so pausing playback
/// doesn't remove the controls. Never retain stale Core Audio process IDs.
struct AudioAppList {
    private var heardApps: Set<String> = []

    mutating func visibleApps(
        from discovered: [AudioApplication], settings: [String: MixerSettings],
        retained: [AudioApplication] = []
    )
        -> [AudioApplication]
    {
        heardApps.formIntersection(discovered.map(\.id))
        heardApps.formUnion(discovered.filter(\.playing).map(\.id))
        let retainedIDs = Set(retained.map(\.id))
        var visible = discovered.filter {
            retainedIDs.contains($0.id) || heardApps.contains($0.id)
                || (settings[$0.id] ?? MixerSettings()).shouldPersist
        }
        var visibleIDs = Set(visible.map(\.id))
        for app in retained where visibleIDs.insert(app.id).inserted {
            // Keep only display metadata. A relaunched app must supply fresh audio clients.
            visible.append(AudioApplication(id: app.id, name: app.name, path: app.path))
        }
        return visible.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
