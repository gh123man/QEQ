import AppKit
import AppMixerAppSupport
import AppMixerCore
import SwiftUI

@MainActor
final class MixerModel: ObservableObject {
    @Published var snapshot = MixerSnapshot()
    @Published var settings: [String: MixerSettings] = [:]
    @Published var enabled = false
    @Published var changing = false
    @Published var selectedEQ: String?
    @Published var telemetry = AudioTelemetry()
    private var panelVisible = false
    private let engine = MixerEngine()
    private var observers: [NSObjectProtocol] = []
    private var saveWork: DispatchWorkItem?

    init() {
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
            let saved = try? JSONDecoder().decode([String: MixerSettings].self, from: data)
        {
            settings = saved.mapValues { $0.sanitized() }
        }
        engine.start(settings: settings) { [weak self] value in
            Task { @MainActor in
                if let self, !value.migratedIDs.isEmpty {
                    for (old, new) in value.migratedIDs {
                        if self.settings[new] == nil { self.settings[new] = self.settings[old] }
                        self.settings.removeValue(forKey: old)
                    }
                    self.save()
                }
                self?.snapshot = value
                self?.enabled = value.enabled
                self?.changing = false
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.engine.suspend(true) }
            })
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.engine.suspend(false) }
            })
    }
    func toggle(_ value: Bool) {
        enabled = value
        changing = true
        engine.setEnabled(value)
    }
    func value(_ id: String) -> MixerSettings { settings[id] ?? MixerSettings() }
    func edit(_ id: String, _ edit: (inout MixerSettings) -> Void) {
        var value = value(id)
        edit(&value)
        value = value.sanitized()
        settings[id] = value
        engine.update(id, settings: value)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func save() {
        if let data = try? JSONEncoder().encode(settings.filter { $0.value.shouldPersist }) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
    }
    func selectEQ(_ id: String) {
        selectedEQ = selectedEQ == id ? nil : id
        refreshAnalysis()
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        refreshAnalysis()
    }
    private func refreshAnalysis() {
        engine.setAnalysisApp(panelVisible ? selectedEQ : nil) { [weak self] value in
            Task { @MainActor in self?.telemetry = value }
        }
    }
    func shutdown() {
        save()
        engine.shutdown()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = MixerModel()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--audio-check=") }) {
            let bundleID = String(argument.dropFirst("--audio-check=".count))
            model.shutdown()
            DispatchQueue.global(qos: .userInitiated).async {
                print(AudioDiagnostics.check(bundleID: bundleID))
                Task { @MainActor in NSApp.terminate(nil) }
            }
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "AppMixer")
        item.button?.toolTip = "Audio mixer"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 500, height: 720)
        popover.contentViewController = NSHostingController(rootView: MixerView(model: model))
        // Show the controls once at launch so a menu-bar-only app is easy to find.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPopover() }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item.button else { return }
        model.setPanelVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { model.setPanelVisible(false) }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

@main
struct AppMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
