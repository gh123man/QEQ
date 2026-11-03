import AppKit
import QEQAppSupport
import QEQCore
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
    @Published var animateEQReveal = false
    @Published var telemetry = AudioTelemetry()
    static let panelHeightLimit: CGFloat = 1000
    @Published var maximumPanelHeight: CGFloat = MixerModel.panelHeightLimit
    private let preview: Bool
    private let spectrumColors = AppSpectrumColors()
    private var icons: [String: NSImage] = [:]
    private let preferences = MixerPreferences()
    private var panelVisible = false
    private let engine = MixerEngine()
    private var observers: [NSObjectProtocol] = []
    private var saveWork: DispatchWorkItem?
    var showSettings: (() -> Void)?
    let exclusions: AppExclusions

    init(preview: Bool = false) {
        self.preview = preview
        exclusions = AppExclusions(defaults: preview ? nil : .standard)
        guard !preview else { return }
        exclusions.onChange = { [weak self] ids in
            guard let self else { return }
            self.snapshot.apps.removeAll { AppExclusions.contains($0, ids: ids) }
            if let selected = self.selectedEQ, selected != Self.globalEQID,
                !self.snapshot.apps.contains(where: { $0.id == selected })
            {
                self.selectedEQ = nil
                self.refreshAnalysis()
            }
            self.telemetry = AudioTelemetry()
            self.engine.setExcludedApps(ids)
        }
        enabled = preferences.enabled
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
        engine.start(settings: settings, global: globalEQ, enabled: enabled, excludedIDs: exclusions.ids) {
            [weak self] value in
            Task { @MainActor in
                if let self, !value.migratedIDs.isEmpty {
                    for (old, new) in value.migratedIDs {
                        if self.settings[new] == nil { self.settings[new] = self.settings[old] }
                        self.settings.removeValue(forKey: old)
                    }
                    self.save()
                }
                guard let self else { return }
                var visible = value
                visible.apps.removeAll { AppExclusions.contains($0, ids: self.exclusions.ids) }
                if self.snapshot != visible { self.snapshot = visible }
                if self.enabled != value.enabled { self.enabled = value.enabled }
                if self.changing { self.changing = false }
                let paths = Set(value.apps.compactMap(\.path))
                self.icons = self.icons.filter { paths.contains($0.key) }
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
        let version = Bundle.main.object(forInfoDictionaryKey: "QEQReleaseVersion") as? String ?? "development"
        let channel = Bundle.main.object(forInfoDictionaryKey: "QEQBuildChannel") as? String ?? "development"
        let apps = snapshot.apps.map { app in
            "\(app.name): playing=\(app.playing), clients=\(app.processes), outputs=\(app.outputDevices.map { String(describing: $0.sorted()) } ?? "unknown"), enabled=\(value(app.id).enabled), adjusted=\(value(app.id).needsProcessing), frames=\(snapshot.callbackFrames[app.id] ?? 0), status=\(snapshot.routeMessages[app.id] ?? "normal")"
        }.joined(separator: "\n")
        return
            "QEQ \(version) (\(channel))\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nOutput: \(snapshot.outputName), \(snapshot.sampleRate) Hz\n\(snapshot.timing)\nMixer enabled: \(enabled)\nGlobal EQ active: \(globalEQ.hasEnabledEQ)\n\(snapshot.error ?? "No errors")\n\(apps)"
    }
    var diagnosticReport: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var values = settings.filter { $0.value.shouldPersist }
        values[Self.globalEQID] = globalEQ
        let data = (try? encoder.encode(values)) ?? Data()
        return diagnostics + "\nExcluded apps: \(exclusions.ids.sorted())\n\nEQ settings\n"
            + String(decoding: data, as: UTF8.self)
    }
    func toggle(_ value: Bool) {
        if !preview { AppLog.shared.write(.info, "Processing enabled: \(value)") }
        enabled = value
        if !preview { preferences.enabled = value }
        changing = true
        engine.setEnabled(value)
    }
    func value(_ id: String) -> MixerSettings { id == Self.globalEQID ? globalEQ : settings[id] ?? MixerSettings() }
    func icon(for app: AudioApplication) -> NSImage? {
        guard let path = app.path else { return nil }
        if let icon = icons[path] { return icon }
        if !preview {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icons[path] = icon
            return icon
        }
        // Headless macOS runners can block indefinitely in IconServices. Fixture
        // rendering reads the bundle's icon directly and uses the view's fallback
        // symbol when an installed app has no standalone icon resource.
        guard let bundle = Bundle(path: path),
            let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
            let resource = bundle.resourceURL?.appendingPathComponent(
                (name as NSString).pathExtension.isEmpty ? name + ".icns" : name)
        else { return nil }
        let icon = NSImage(contentsOf: resource)
        icons[path] = icon
        return icon
    }
    func spectrumColor(for app: AudioApplication) -> Color {
        Color(nsColor: spectrumColors.color(for: app.id, icon: icon(for: app)))
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
        AppLog.shared.write(
            .debug,
            "Saving settings: \(settings.filter { $0.value.shouldPersist }.count) apps, global EQ=\(globalEQ.hasEnabledEQ)"
        )
        if let data = try? JSONEncoder().encode(settings.filter { $0.value.shouldPersist }) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
        if let data = try? JSONEncoder().encode(globalEQ) {
            UserDefaults.standard.set(data, forKey: "globalEQ")
        }
    }
    func selectEQ(_ id: String) {
        animateEQReveal = true
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
            Task { @MainActor in
                guard let self, self.telemetry != value else { return }
                self.telemetry = value
            }
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
    let updates = UpdateStore(
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "QEQReleaseVersion") as? String ?? "0.1.0",
        distribution: Bundle.main.object(forInfoDictionaryKey: "QEQBuildChannel") as? String == "release",
        defaults: CommandLine.arguments.contains("--render-screenshots") ? nil : .standard,
        logger: CommandLine.arguments.contains("--render-screenshots") ? nil : .shared)
    private lazy var loginItem = LoginItemStore()
    private lazy var installer = UpdateInstaller(store: updates)
    private lazy var settingsWindow = SettingsWindowController(
        updates: updates, loginItem: loginItem, exclusions: model.exclusions
    ) { [weak self] in
        self?.model.diagnosticReport ?? "QEQ is not running."
    }
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var mixerHost: NSHostingController<MixerView>?
    private var performanceRecorder: PerformanceRecorder?
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
        AppLog.shared.write(.info, "QEQ started, version \(updates.currentVersion)")
        updates.installHandler = { [weak self] release in self?.installer.install(release) }
        updates.start()
        loginItem.start()
        model.showSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.settingsWindow.show()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.makeImage()
        item.button?.toolTip = "QEQ · Quick EQ"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: MixerView(model: model, updates: updates))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        mixerHost = host
        // Show the controls once at launch so a menu-bar-only app is easy to find.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.showPopover()
            if let index = CommandLine.arguments.firstIndex(of: "--profile-performance"),
                index + 1 < CommandLine.arguments.count
            {
                let recorder = PerformanceRecorder()
                self.performanceRecorder = recorder
                recorder.start(
                    path: CommandLine.arguments[index + 1], model: self.model,
                    isVisible: { [weak self] in self?.popover.isShown == true },
                    setVisible: { [weak self] visible in
                        if visible { self?.showPopover() } else { self?.popover.performClose(nil) }
                    })
            }
        }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item.button, let host = mixerHost else { return }
        model.animateEQReveal = false
        model.maximumPanelHeight = min(
            MixerModel.panelHeightLimit,
            max(280, (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 768) - 48)
        popover.contentSize = PopoverLayout.prepare(host, maximumHeight: model.maximumPanelHeight)
        model.setPanelVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { model.setPanelVisible(false) }
    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        AppLog.shared.write(.info, "QEQ shutting down; restoring system audio")
        model.shutdown()
    }
}

@main
struct QEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
