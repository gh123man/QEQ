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
        runningApps: [NSRunningApplication]
    ) -> Self {
        var url = containingApp(bundleURL) ?? containingApp(executableURL)
        // Some browser helpers expose only a bundle ID. Use the longest actual
        // running parent ID with a component boundary, never a display-name guess.
        if url == nil,
            let owner = runningApps.filter({ app in
                guard let id = app.bundleIdentifier else { return false }
                return app.activationPolicy == .regular && (bundleID == id || bundleID.hasPrefix(id + "."))
            }).max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) })
        {
            url = containingApp(owner.bundleURL)
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
