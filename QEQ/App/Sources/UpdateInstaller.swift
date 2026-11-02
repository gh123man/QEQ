import AppKit
import QEQAppSupport
@preconcurrency import Sparkle
import SwiftUI

/// Sparkle is created only after an explicit click. It owns verification,
/// installation, authorization (if needed), and relaunch, not audio processing.
@MainActor
final class UpdateInstaller: NSObject, SPUUpdaterDelegate {
    private let store: UpdateStore
    private var controller: SPUStandardUpdaterController?
    private var release: AvailableUpdate?
    init(store: UpdateStore) { self.store = store }
    func install(_ release: AvailableUpdate) {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            Data(base64Encoded: key)?.count == 32
        else {
            store.installFinished(error: UpdateError.unavailable)
            return
        }
        self.release = release
        if controller == nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
    func feedURLString(for updater: SPUUpdater) -> String? { release?.feedURL.absoluteString }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        store.installStatus("Downloading update…")
    }
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        store.installStatus("Verifying update…")
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        store.installStatus("Installing update…")
        AppLog.shared.write(.info, "Installing QEQ update \(release?.version ?? "unknown")")
        // Keep audio working through download/confirmation. Normal app termination
        // releases all taps just before Sparkle relaunches the new version.
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        store.installFinished(error: error)
    }
}

struct UpdateAvailableButton: View {
    @ObservedObject var updates: UpdateStore
    var body: some View {
        if updates.available != nil {
            Button(updates.installing ? "Updating…" : "Update available") { updates.install() }
                .font(.system(size: 10, weight: .medium)).buttonStyle(.borderless)
                .disabled(updates.installing)
                .help(updates.available.map { "Install QEQ \($0.version)" } ?? "Update QEQ")
        }
    }
}
