import AppKit
import QEQAppSupport
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var updates: UpdateStore
    @ObservedObject var loginItem: LoginItemStore
    let diagnostics: () -> String
    let preview: Bool
    @State private var logLevel: LogLevel
    @State private var collecting = false
    @State private var logMessage = ""

    init(updates: UpdateStore, loginItem: LoginItemStore, preview: Bool = false, diagnostics: @escaping () -> String) {
        self.updates = updates
        self.loginItem = loginItem
        self.preview = preview
        self.diagnostics = diagnostics
        _logLevel = State(initialValue: preview ? .warning : AppLog.shared.level)
    }
    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Start with macOS",
                    isOn: Binding(
                        get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.requiresApproval {
                    Text("Allow QEQ in Login Items to start automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items…") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: updates.currentVersion)
                Toggle(
                    "Check automatically", isOn: Binding(get: { updates.automatic }, set: { updates.setAutomatic($0) }))
                Toggle(
                    "Include release candidates",
                    isOn: Binding(get: { updates.includeRC }, set: { updates.setIncludeRC($0) })
                )
                .disabled(updates.installing)
                HStack {
                    Button(updates.checking ? "Checking…" : "Check now") { updates.checkNow() }
                        .disabled(updates.checking || updates.installing)
                    if updates.available != nil { UpdateAvailableButton(updates: updates) }
                    Spacer()
                    if updates.checking || updates.installing { ProgressView().controlSize(.small) }
                }
                Text(updates.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !updates.distribution {
                    Text("Development build: automatic checks and installation are off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Diagnostics") {
                Picker(
                    "Log level",
                    selection: Binding(
                        get: { logLevel },
                        set: { value in
                            logLevel = value
                            guard !preview else { return }
                            AppLog.shared.level = value
                            UserDefaults.standard.set(value.rawValue, forKey: AppLog.levelKey)
                            AppLog.shared.write(value, "Log level changed to \(value.label)")
                        })
                ) {
                    ForEach(LogLevel.allCases) { level in Text(level.label).tag(level) }
                }
                Text(
                    "Choose Debug before reproducing an issue. Logs include app names, device details and errors; no audio is recorded or uploaded."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(collecting ? "Collecting…" : "Save diagnostic log…") { collect() }
                        .disabled(collecting)
                    Button("Clear logs") {
                        guard !preview else { return }
                        Task {
                            do {
                                try await AppLog.shared.clear()
                                logMessage = "Logs cleared."
                            } catch { logMessage = "Couldn’t clear logs: \(error.localizedDescription)" }
                        }
                    }.disabled(collecting)
                }
                if !logMessage.isEmpty {
                    Text(logMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.formStyle(.grouped).padding(12).frame(width: 470, height: 580)
            .onAppear { loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginItem.refresh()
            }
    }
    private func collect() {
        guard !preview else { return }
        collecting = true
        logMessage = ""
        let snapshot =
            diagnostics()
            + "\nStart with macOS: \(loginItem.status.rawValue)\nUpdates: automatic=\(updates.automatic), includeRC=\(updates.includeRC)\nLog level: \(logLevel.rawValue)"
        Task { @MainActor in
            defer { collecting = false }
            do {
                let data = try await AppLog.shared.collect(diagnostics: snapshot)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = "QEQ-diagnostics-\(Date().formatted(.iso8601.year().month().day())).txt"
                let response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                guard response == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                logMessage = "Diagnostic log saved."
            } catch { logMessage = "Couldn’t save logs: \(error.localizedDescription)" }
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let controller: NSWindowController
    init(updates: UpdateStore, loginItem: LoginItemStore, diagnostics: @escaping () -> String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 580),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(updates: updates, loginItem: loginItem, diagnostics: diagnostics))
        window.center()
        controller = NSWindowController(window: window)
    }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
