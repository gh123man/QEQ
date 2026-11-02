import AppKit
import QEQAppSupport
import QEQCore
import SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var globalBand = 0
    @State private var measured: [String: CGFloat] = [:]
    private var isAppEQExpanded: Bool {
        model.snapshot.apps.contains { $0.id == model.selectedEQ }
    }
    private var panelHeight: CGFloat {
        min(
            model.maximumPanelHeight,
            measured["header", default: 100] + measured["apps", default: 110])
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    Text(model.snapshot.outputName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    if model.changing { ProgressView().controlSize(.mini) }
                    Toggle("Enabled", isOn: Binding(get: { model.enabled }, set: { model.toggle($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .help("Off restores original audio for every app.")
                    Menu {
                        Button("Copy diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.diagnostics, forType: .string)
                        }
                        Divider()
                        Button("Quit") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("QEQ options")
                    .accessibilityLabel("QEQ options")
                }.padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                if let error = model.snapshot.error {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.enabled ? "Some apps are bypassed" : "System audio restored").font(
                            .system(size: 11, weight: .semibold))
                        Text(error).font(.system(size: 11)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                            .help(error)
                        HStack {
                            Button("Retry") { model.toggle(true) }
                            Button("Privacy settings") {
                                NSWorkspace.shared.open(
                                    URL(
                                        string:
                                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                                    )!
                                )
                            }
                        }
                    }.foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                        .orange.opacity(0.08))
                }
                globalSection
                Divider()
            }.fixedSize(horizontal: false, vertical: true).trackHeight("header")
            ScrollView {
                VStack(spacing: 8) {
                    if model.snapshot.apps.isEmpty {
                        VStack(spacing: 8) {
                            Text("No audio apps yet").font(
                                .system(size: 12, weight: .medium))
                            Text("Start playback to see an app here. Apps with saved adjustments also appear.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(30)
                    }
                    ForEach(model.snapshot.apps) { app in appCard(app) }
                }.padding(.horizontal, 12).padding(.vertical, 12)
                    .fixedSize(horizontal: false, vertical: true).trackHeight("apps")
            }.frame(maxHeight: .infinity)

        }.frame(width: 500, height: panelHeight, alignment: .top).clipped().tint(.accentColor)
            .background(Color(nsColor: .windowBackgroundColor))
            .onPreferenceChange(PanelHeights.self) { heights in
                guard measured != heights else { return }
                // Geometry feeds the viewport size: never interpolate these
                // measurements or retain an outgoing editor in the layout.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { measured = heights }
            }
    }
    private var globalSection: some View {
        let selected = model.selectedEQ == MixerModel.globalEQID
        return VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19)).frame(width: 25)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global EQ").font(.system(size: 12, weight: .medium))
                    Text(model.globalEQ.enabled ? "All apps on this output" : "Global EQ bypassed")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.selectEQ(MixerModel.globalEQID)
                } label: {
                    HStack(spacing: 4) {
                        Text("EQ")
                        Image(systemName: "chevron.down").font(.system(size: 8))
                            .rotationEffect(.degrees(selected ? 180 : 0))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: selected)
                    }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).accessibilityLabel("Global equalizer")
                Toggle(
                    "Global EQ",
                    isOn: Binding(
                        get: { model.globalEQ.enabled },
                        set: { enabled in
                            model.edit(MixerModel.globalEQID) { $0.enabled = enabled }
                        })
                ).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Bypass Global EQ while keeping each app's settings.")
            }.padding(.horizontal, 16).padding(.top, 12)
            if !isAppEQExpanded {
                ParametricEQView(
                    model: model, appID: MixerModel.globalEQID, compact: true,
                    overviewHandles: selected, selection: $globalBand
                )
                .modifier(EQContentReveal())
            }
            if selected {
                ParametricEQView(
                    model: model, appID: MixerModel.globalEQID,
                    controlsOnly: true, selection: $globalBand
                )
                .padding(.horizontal, 16).padding(.top, 4)
                .modifier(EQContentReveal())
            }
        }.padding(.bottom, 10)
    }
    private func appCard(_ app: AudioApplication) -> some View {
        let settings = model.value(app.id)
        let selected = model.selectedEQ == app.id
        return VStack(spacing: 9) {
            HStack(spacing: 9) {
                if let icon = model.icon(for: app) {
                    Image(nsImage: icon).resizable().frame(width: 25, height: 25)
                } else {
                    Image(systemName: "app").font(.system(size: 22)).frame(width: 25)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(status(app, settings: settings)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(
                        1
                    ).help(status(app, settings: settings))
                }
                Spacer()
                Button {
                    model.edit(app.id) {
                        $0.muted.toggle()
                        if $0.muted { $0.enabled = true }
                    }
                } label: {
                    Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundStyle(settings.muted ? Color.accentColor : .secondary)
                        .frame(width: 28, height: 24)
                        .background(
                            settings.muted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help(settings.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                    .accessibilityLabel(settings.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                Button {
                    model.selectEQ(app.id)
                } label: {
                    HStack(spacing: 4) {
                        Text("EQ")
                        Image(systemName: "chevron.down").font(.system(size: 8))
                            .rotationEffect(.degrees(selected ? 180 : 0))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: selected)
                    }
                    .font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).accessibilityLabel("Equalizer for \(app.name)")
                Toggle(
                    "Process \(app.name)",
                    isOn: Binding(
                        get: { model.value(app.id).enabled }, set: { new in model.edit(app.id) { $0.enabled = new } })
                )
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help("Bypass this app's volume and EQ while keeping its settings. Global EQ still applies.")
            }
            HStack(spacing: 9) {
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
                    .modifier(EQContentReveal())
            } else {
                activityMeter(app)
                    .modifier(EQContentReveal())
            }
        }.padding(11).background(
            Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
    }
    private func activityMeter(_ app: AudioApplication) -> some View {
        let available = model.enabled && app.playing && model.snapshot.active.contains(app.id)
        let peak = available ? (model.telemetry.apps[app.id]?.peak ?? 0) : 0
        let db = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        let fraction = max(0, min(1, (db + 60) / 60))
        let label = !available ? "—" : (peak > 0 ? String(format: "%.0f dBFS", db) : "−∞ dBFS")
        return HStack(spacing: 7) {
            Text("Output").foregroundStyle(.tertiary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: geometry.size.width * fraction)
                }
            }.frame(height: 4)
                .animation(.linear(duration: 0.067), value: fraction)
            Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 51, alignment: .trailing)
        }.font(.system(size: 9))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(app.name) output level")
            .accessibilityValue(available ? label : "Not metered")
            .help(
                model.enabled
                    ? "Live output peak after app volume, mute, and both EQs. Meter scale: −60 to 0 dBFS."
                    : "Turn on the master switch to show live output levels. Bypass releases all audio taps.")
    }
    private func status(_ app: AudioApplication, settings: MixerSettings) -> String {
        if !settings.enabled && !(model.enabled && model.globalEQ.hasEnabledEQ) { return "App bypassed" }
        if !model.enabled { return "System bypass" }
        if let message = model.snapshot.routeMessages[app.id] { return message }
        if model.snapshot.active.contains(app.id) {
            if !settings.enabled { return "Global EQ only" }
            return settings.muted ? "Muted" : "Processing"
        }
        if settings.isFlat { return app.playing ? "Playing · original audio" : "Idle · original audio" }
        return "Starting…"
    }
}

/// Slide and fade content inside its final bounds, without moving its siblings.
/// Clipping contains the motion; the popup and scroll layout never interpolate.
private struct EQContentReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion || visible ? 0 : -24)
            .opacity(reduceMotion || visible ? 1 : 0)
            .clipped()
            .task(id: reduceMotion) {
                guard !reduceMotion else {
                    visible = true
                    return
                }
                // An immediate task can finish before the first rendered frame,
                // coalescing both opacity values into an invisible transition.
                // Let initial layout and its nonanimated measurements settle first.
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
                withAnimation(.easeOut(duration: 0.28)) { visible = true }
            }
            .onDisappear { visible = false }
    }
}

private struct PanelHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    fileprivate func trackHeight(_ section: String) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: PanelHeights.self, value: [section: geometry.size.height])
            })
    }
}
