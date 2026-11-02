import AppKit
import Foundation

struct AppIdentity {
    let id: String
    let name: String
    let url: URL?

    static func containingApp(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var parent = url.standardizedFileURL
        var outer: URL?
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "app" { outer = parent }
            parent.deleteLastPathComponent()
        }
        return outer
    }
    static func resolve(
        bundleURL: URL?, executableURL: URL?, bundleID: String, fallbackName: String,
        runningApps: [(id: String, app: NSRunningApplication)]
    ) -> Self {
        var url = containingApp(bundleURL) ?? containingApp(executableURL)
        // Some browser helpers expose only a bundle ID. Use the longest actual
        // running parent ID with a component boundary, never a display-name guess.
        if url == nil,
            let owner = runningApps.filter({ candidate in
                // activationPolicy queries LaunchServices. Reject unrelated IDs before that IPC.
                return (bundleID == candidate.id || bundleID.hasPrefix(candidate.id + "."))
                    && candidate.app.activationPolicy == .regular
            }).max(by: { $0.id.count < $1.id.count })
        {
            url = containingApp(owner.app.bundleURL)
        }
        // Read the outer app's plist directly: NSBundle can reuse an already-loaded
        // helper bundle by identity. Its metadata must not leak into the parent row.
        let info = url.flatMap {
            NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        }
        let id = (info?["CFBundleIdentifier"] as? String) ?? bundleID
        let name =
            (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url?.deletingPathExtension().lastPathComponent ?? fallbackName
        return Self(id: id, name: name, url: url)
    }
}

/// Control-queue cache of display metadata only. Playback, output devices and
/// process membership must still be read on every discovery tick.
final class AppIdentityCache {
    private struct Entry {
        let pid: Int32
        let bundleID: String
        let identity: AppIdentity
        let expires: TimeInterval
    }
    private var entries: [UInt32: Entry] = [:]
    func retain(processes: [UInt32]) {
        let live = Set(processes)
        entries = entries.filter { live.contains($0.key) }
    }
    func identity(
        object: UInt32, pid: Int32, bundleID: String, now: TimeInterval, resolve: () -> AppIdentity
    ) -> AppIdentity {
        if let entry = entries[object], entry.pid == pid, entry.bundleID == bundleID, now < entry.expires {
            return entry.identity
        }
        let identity = resolve()
        // Retry unresolved helpers next tick; their parent may still be launching.
        if identity.url != nil {
            entries[object] = Entry(pid: pid, bundleID: bundleID, identity: identity, expires: now + 30)
        } else {
            entries.removeValue(forKey: object)
        }
        return identity
    }
}
