import AppKit
import AppMixerAppSupport
import AppMixerCore
import SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @State private var search = ""
    private var apps: [AudioApplication] {
        model.snapshot.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Text(model.snapshot.outputName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if model.changing { ProgressView().controlSize(.mini) }
                Toggle("Mixer", isOn: Binding(get: { model.enabled }, set: { model.toggle($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                    .help("Off restores original audio for every app.")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let error = model.snapshot.error {
                VStack(alignment: .leading, spacing: 7) {
                    Text("System audio restored").font(.system(size: 11, weight: .semibold))
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Retry") { model.toggle(true) }
                        Button("Privacy settings") {
                            NSWorkspace.shared.open(
                                URL(
                                    string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
                            )
                        }
                    }
                }.foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                    .orange.opacity(0.08))
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter apps", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain)
                }
            }.font(.system(size: 11)).padding(8).background(
                .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6)
            ).padding(12)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if apps.isEmpty {
                        VStack(spacing: 8) {
                            Text(search.isEmpty ? "No audio apps yet" : "No matching apps").font(
                                .system(size: 12, weight: .medium))
                            Text("Start playback to see an app here. Apps with saved adjustments also appear.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(30)
                    }
                    ForEach(apps) { app in appCard(app) }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model.enabled
                            ? "\(model.snapshot.active.count) apps processing" : "Bypassed · original system audio")
                    Text(model.snapshot.timing).foregroundStyle(.tertiary)
                        .help("Hardware buffer duration, not measured end-to-end latency.")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(width: 500, height: 720).tint(.teal)
    }
    private func appCard(_ app: AudioApplication) -> some View {
        let settings = model.value(app.id)
        let selected = model.selectedEQ == app.id
        return VStack(spacing: 9) {
            HStack(spacing: 9) {
                if let path = app.path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 25, height: 25)
                } else {
                    Image(systemName: "app").font(.system(size: 22)).frame(width: 25)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(status(app, settings: settings)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.selectEQ(app.id)
                } label: {
                    HStack(spacing: 4) {
                        Text("EQ")
                        Image(systemName: selected ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        selected ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).accessibilityLabel("Equalizer for \(app.name)")
                Toggle(
                    "Process \(app.name)",
                    isOn: Binding(
                        get: { model.value(app.id).enabled }, set: { new in model.edit(app.id) { $0.enabled = new } })
                )
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help("Bypass this app's volume and EQ while keeping its settings.")
            }
            HStack(spacing: 9) {
                Button {
                    model.edit(app.id) { $0.muted.toggle() }
                } label: {
                    Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundStyle(settings.muted ? Color.orange : .secondary).frame(width: 18)
                }.buttonStyle(.plain).help(settings.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                Slider(
                    value: Binding(
                        get: { model.value(app.id).volume }, set: { value in model.edit(app.id) { $0.volume = value } }),
                    in: 0...1
                )
                .accessibilityLabel("\(app.name) volume")
                Text("\(Int((settings.volume * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(
                        width: 33, alignment: .trailing)
            }.opacity(settings.enabled ? 1 : 0.55)
            if selected {
                Divider()
                ParametricEQView(model: model, appID: app.id)
            }
        }.padding(11).background(
            Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
    }
    private func status(_ app: AudioApplication, settings: MixerSettings) -> String {
        if !settings.enabled { return "App bypassed" }
        if !model.enabled { return "System bypass" }
        if model.snapshot.active.contains(app.id) { return settings.muted ? "Muted" : "Processing" }
        if settings.isFlat { return app.playing ? "Playing · original audio" : "Idle · original audio" }
        return "Starting…"
    }
}
