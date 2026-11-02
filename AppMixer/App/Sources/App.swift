import AppKit
import AppMixerAppSupport
import AppMixerCore
import SwiftUI

@MainActor
final class MixerModel: ObservableObject {
    @Published var snapshot = MixerSnapshot()
    @Published var settings: [String: MixerSettings] = [:]
    @Published var globalEQ = MixerSettings()
    static let globalEQID = MixerEngine.globalEQID
    @Published var enabled = false
    @Published var changing = false
    @Published var selectedEQ: String?
    @Published var telemetry = AudioTelemetry()
    static let panelHeightLimit: CGFloat = 1000
    @Published var maximumPanelHeight: CGFloat = MixerModel.panelHeightLimit
    private let preview: Bool
    private var panelVisible = false
    private let engine = MixerEngine()
    private var observers: [NSObjectProtocol] = []
    private var saveWork: DispatchWorkItem?

    init(preview: Bool = false) {
        self.preview = preview
        guard !preview else { return }
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
            let saved = try? JSONDecoder().decode([String: MixerSettings].self, from: data)
        {
            settings = saved.mapValues { $0.sanitized() }
        }
        if let data = UserDefaults.standard.data(forKey: "globalEQ"),
            let saved = try? JSONDecoder().decode(MixerSettings.self, from: data)
        {
            globalEQ = saved.sanitized()
            globalEQ.volume = 1
            globalEQ.muted = false
        }
        engine.start(settings: settings, global: globalEQ) { [weak self] value in
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
    var diagnostics: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "AppMixerReleaseVersion") as? String ?? "development"
        let apps = snapshot.apps.map { app in
            "\(app.name): playing=\(app.playing), clients=\(app.processes), outputs=\(app.outputDevices.map { String(describing: $0.sorted()) } ?? "unknown"), enabled=\(value(app.id).enabled), adjusted=\(value(app.id).needsProcessing), frames=\(snapshot.callbackFrames[app.id] ?? 0), status=\(snapshot.routeMessages[app.id] ?? "normal")"
        }.joined(separator: "\n")
        return
            "QEQ \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nOutput: \(snapshot.outputName), \(snapshot.sampleRate) Hz\n\(snapshot.timing)\nMixer enabled: \(enabled)\nGlobal EQ active: \(globalEQ.hasEnabledEQ)\n\(snapshot.error ?? "No errors")\n\(apps)"
    }
    func toggle(_ value: Bool) {
        enabled = value
        changing = true
        engine.setEnabled(value)
    }
    func value(_ id: String) -> MixerSettings { id == Self.globalEQID ? globalEQ : settings[id] ?? MixerSettings() }
    func icon(for app: AudioApplication) -> NSImage? {
        guard let path = app.path else { return nil }
        guard preview else { return NSWorkspace.shared.icon(forFile: path) }
        // Headless macOS runners can block indefinitely in IconServices. Fixture
        // rendering reads the bundle's icon directly and uses the view's fallback
        // symbol when an installed app has no standalone icon resource.
        guard let bundle = Bundle(path: path),
            let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
            let resource = bundle.resourceURL?.appendingPathComponent(
                (name as NSString).pathExtension.isEmpty ? name + ".icns" : name)
        else { return nil }
        return NSImage(contentsOf: resource)
    }
    func edit(_ id: String, _ edit: (inout MixerSettings) -> Void) {
        var value = value(id)
        edit(&value)
        value = value.sanitized()
        if id == Self.globalEQID {
            value.volume = 1
            value.muted = false
            globalEQ = value
            engine.setGlobalEQ(value)
        } else {
            settings[id] = value
            engine.update(id, settings: value)
        }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func save() {
        guard !preview else { return }
        if let data = try? JSONEncoder().encode(settings.filter { $0.value.shouldPersist }) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
        if let data = try? JSONEncoder().encode(globalEQ) {
            UserDefaults.standard.set(data, forKey: "globalEQ")
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
        engine.setAnalysisApp(panelVisible ? (selectedEQ ?? Self.globalEQID) : nil, includeGlobal: panelVisible) {
            [weak self] value in
            Task { @MainActor in self?.telemetry = value }
        }
    }
    func shutdown() {
        guard !preview else { return }
        save()
        engine.shutdown()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = MixerModel(preview: CommandLine.arguments.contains("--render-screenshots"))
    private var item: NSStatusItem!
    private let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--render-screenshots"),
            index + 1 < CommandLine.arguments.count
        {
            do {
                try ScreenshotRenderer.render(
                    to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            } catch {
                fputs("Screenshot rendering failed: \(error)\n", stderr)
                exit(1)
            }
            NSApp.terminate(nil)
            return
        }
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
        item.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "QEQ")
        item.button?.toolTip = "QEQ · Quick EQ"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 500, height: 240)
        let host = NSHostingController(rootView: MixerView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Show the controls once at launch so a menu-bar-only app is easy to find.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPopover() }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item.button else { return }
        model.maximumPanelHeight = min(
            MixerModel.panelHeightLimit,
            max(280, (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 768) - 48)
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
