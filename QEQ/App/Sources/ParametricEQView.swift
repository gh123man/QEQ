import QEQAppSupport
import QEQCore
import SwiftUI

struct ParametricEQView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: MixerModel
    let appID: String
    var compact = false
    var controlsOnly = false
    var overviewHandles = false
    var selection: Binding<Int>?
    @State private var localSelected = 0
    private var selected: Int {
        get { selection?.wrappedValue ?? localSelected }
        nonmutating set {
            if let selection { selection.wrappedValue = newValue } else { localSelected = newValue }
        }
    }
    private var settings: MixerSettings { model.value(appID) }
    private var band: EQBand { settings.bands[selected] }
    private var isGlobal: Bool { appID == MixerModel.globalEQID }
    private var telemetry: AudioTelemetry {
        isGlobal ? model.telemetry : model.telemetry.apps[appID] ?? AudioTelemetry()
    }
    private var spectrumApps: [AudioApplication] {
        // The legend is known before taps start delivering telemetry.
        Array(model.snapshot.apps.filter { $0.playing }.prefix(6))
    }
    private var processing: Bool {
        model.enabled
            && (isGlobal ? !model.snapshot.active.isEmpty : settings.enabled && model.snapshot.active.contains(appID))
    }
    private var maxFrequency: Double { min(20000, model.snapshot.sampleRate * 0.45) }
    private let colors: [Color] = [.orange, .yellow, .teal, .blue, .purple]

    var body: some View {
        VStack(spacing: 10) {
            if !controlsOnly {
                HStack(spacing: 5) {
                    Spacer()
                    if processing && !telemetry.spectrum.isEmpty {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        if telemetry.simulated {
                            Text("Simulated spectrum").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if compact && telemetry.limitingDB > 0.1 {
                            Text(String(format: "Limiting −%.1f dB", telemetry.limitingDB))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange)
                                .help(
                                    "Automatic clipping protection is reducing gain. Lower app volume or EQ boosts for more headroom."
                                )
                        } else {
                            Text(
                                telemetry.peak > 0.00003
                                    ? String(format: "%.0f dBFS", 20 * log10(telemetry.peak)) : "−∞ dBFS"
                            )
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(
                                width: 53, alignment: .trailing)
                        }
                    } else {
                        Text(processing ? "Waiting for signal" : "Preview · enable processing for spectrum").font(
                            .system(size: 9)
                        ).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 13)
                .padding(.horizontal, isGlobal ? 16 : 0)
                .help(
                    isGlobal
                        ? "Strongest app in each frequency bin; not a measurement of the summed system output."
                        : "App output after app EQ, Global EQ, volume, and limiting. The curve shows this app's EQ only."
                )
                graph.frame(height: compact ? 150 : 190)
                if isGlobal && !spectrumApps.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(spectrumApps) { app in
                                HStack(spacing: 4) {
                                    Capsule().fill(model.spectrumColor(for: app)).frame(width: 12, height: 2)
                                    Text(app.name).lineLimit(1)
                                }.font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(height: 13).padding(.horizontal, 16)
                }
            }
            if !compact {
                HStack(spacing: 5) {
                    ForEach(0..<5) { index in
                        Button {
                            selected = index
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(settings.bands[index].enabled ? colors[index] : .secondary).frame(
                                    width: 5, height: 5)
                                Text("\(index + 1)")
                            }.font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).padding(
                                .vertical, 6
                            )
                            .background(
                                selected == index ? colors[index].opacity(0.16) : Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel("Select EQ band \(index + 1)")
                    }
                }
                HStack {
                    Toggle("Band \(selected + 1)", isOn: binding(\.enabled)).toggleStyle(.checkbox).font(
                        .system(size: 11))
                    Spacer()
                    Picker(
                        "Filter",
                        selection: Binding(
                            get: { band.type },
                            set: { type in
                                edit {
                                    $0.type = type
                                    $0.q = type.isShelf ? 1 : 0.70710678
                                }
                            })
                    ) {
                        ForEach(EQFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 125, alignment: .trailing).controlSize(.small)
                }
                HStack(spacing: 12) {
                    numberControl(
                        "Frequency", unit: "Hz", value: binding(\.frequency), range: 20...maxFrequency, decimals: 0)
                    numberControl("Gain", unit: "dB", value: binding(\.gain), range: -18...18, decimals: 1).disabled(
                        !band.type.hasGain
                    ).help(
                        String(
                            format:
                                "%.1f dB ≈ %.0f%% amplitude in the affected range. A cut reduces audio; it does not mute it.",
                            band.gain, 100 * pow(10, band.gain / 20)))
                    numberControl(
                        band.type.isShelf ? "Slope" : "Q", unit: "", value: binding(\.q),
                        range: 0.1...(band.type.isShelf ? 1 : 10), decimals: 2)
                }
                HStack(spacing: 8) {
                    Text(band.type.isShelf ? "Slope" : "Width").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(
                            width: 35, alignment: .leading)
                    Slider(
                        value: Binding(get: { log10(band.q) }, set: { value in edit { $0.q = pow(10, value) } }),
                        in: -1...(band.type.isShelf ? 0 : 1)
                    )
                    .accessibilityLabel(band.type.isShelf ? "Shelf slope" : "Band Q")
                    Text(band.type.isShelf ? "Gentle → steep" : "Broad → narrow").font(.system(size: 9))
                        .foregroundStyle(
                            .tertiary)
                }
                HStack {
                    Menu("Presets") {
                        ForEach(EQPreset.allCases) { preset in
                            Button(preset.rawValue) { model.edit(appID) { $0.bands = preset.bands } }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    if processing && telemetry.limitingDB > 0.1 {
                        Label(
                            String(format: "Limiting −%.1f dB", telemetry.limitingDB),
                            systemImage: "waveform.badge.minus"
                        )
                        .foregroundStyle(Color.orange)
                        .help(
                            "Automatic clipping protection is reducing output gain by this amount. Lower app volume or EQ boosts if this happens often. The EQ curve is shown before volume and limiting."
                        )
                    }
                    Button(isGlobal ? "Reset EQ" : "Reset app") { model.edit(appID) { $0 = MixerSettings() } }
                }.font(.system(size: 10)).buttonStyle(.borderless)
            }
        }
    }
    private func edit(_ change: (inout EQBand) -> Void) { model.edit(appID) { change(&$0.bands[selected]) } }
    private func binding<T>(_ key: WritableKeyPath<EQBand, T>) -> Binding<T> {
        Binding(get: { band[keyPath: key] }, set: { value in edit { $0[keyPath: key] = value } })
    }
    private func numberControl(
        _ title: String, unit: String, value: Binding<Double>, range: ClosedRange<Double>, decimals: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField(
                    title,
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }),
                    format: .number.precision(.fractionLength(decimals))
                )
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                .accessibilityLabel("Band \(selected + 1) \(title)")
                if !unit.isEmpty { Text(unit).font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
        }.frame(maxWidth: .infinity)
    }
    private var graph: some View {
        GeometryReader { geometry in
            let rect = CGRect(x: 29, y: 20, width: geometry.size.width - 65, height: geometry.size.height - 43)
            let upper = maxFrequency
            ZStack {
                Canvas { context, size in
                    func x(_ hz: Double) -> CGFloat { rect.minX + log(hz / 20) / log(upper / 20) * rect.width }
                    func y(_ db: Double) -> CGFloat { rect.midY - db / 36 * rect.height }
                    for db in [-90.0, -60, -30, 0] {
                        let levelY = rect.maxY - (db + 90) / 90 * rect.height
                        context.draw(
                            Text(String(format: "%.0f", db)).font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Color.accentColor), at: CGPoint(x: rect.maxX + 17, y: levelY))
                    }
                    context.draw(
                        Text("EQ dB").font(.system(size: 8)).foregroundStyle(.primary.opacity(0.6)),
                        at: CGPoint(x: rect.minX, y: 7), anchor: .leading)
                    context.draw(
                        Text("Output dBFS").font(.system(size: 8)).foregroundStyle(Color.accentColor),
                        at: CGPoint(x: rect.maxX, y: 7), anchor: .trailing)
                    for db in [-18.0, -9, 0, 9, 18] {
                        var line = Path()
                        line.move(to: CGPoint(x: rect.minX, y: y(db)))
                        line.addLine(to: CGPoint(x: rect.maxX, y: y(db)))
                        context.stroke(
                            line, with: .color(.primary.opacity(db == 0 ? (isGlobal ? 0.1 : 0.25) : 0.07)), lineWidth: 1
                        )
                        context.draw(
                            Text(String(format: "%+.0f", db)).font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.45)), at: CGPoint(x: 14, y: y(db)))
                    }
                    for hz in [20.0, 100, 1000, 10000, 20000] where hz <= upper {
                        var line = Path()
                        line.move(to: CGPoint(x: x(hz), y: rect.minY))
                        line.addLine(to: CGPoint(x: x(hz), y: rect.maxY))
                        context.stroke(line, with: .color(.primary.opacity(0.07)), lineWidth: 1)
                        let label = hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
                        context.draw(
                            Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(
                                .primary.opacity(0.45)), at: CGPoint(x: x(hz), y: rect.maxY + 12))
                    }
                }
                spectrumLayer
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                Canvas { context, size in
                    func x(_ hz: Double) -> CGFloat { rect.minX + log(hz / 20) / log(upper / 20) * rect.width }
                    func y(_ db: Double) -> CGFloat { rect.midY - db / 36 * rect.height }
                    var curve = Path()
                    for index in 0...240 {
                        let hz = 20 * pow(upper / 20, Double(index) / 240)
                        let db = settings.responseDB(at: hz, sampleRate: model.snapshot.sampleRate)
                        let point = CGPoint(x: x(hz), y: y(min(18, max(-18, db))))
                        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    context.stroke(
                        curve, with: .color(.primary.opacity(isGlobal ? 0.3 : (processing ? 0.9 : 0.6))),
                        style: StrokeStyle(lineWidth: isGlobal ? 0.8 : 1.6, dash: processing ? [] : [4, 3]))
                }
                if !compact || overviewHandles {
                    ForEach(0..<5) { index in
                        let b = settings.bands[index]
                        let x = rect.minX + log(min(upper, max(20, b.frequency)) / 20) / log(upper / 20) * rect.width
                        let y = rect.midY - (b.type.hasGain ? b.gain : 0) / 36 * rect.height
                        Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                            .frame(width: selected == index ? 21 : 17, height: selected == index ? 21 : 17)
                            .background(b.enabled ? colors[index] : .gray, in: Circle())
                            .overlay(
                                Circle().strokeBorder(.primary.opacity(selected == index ? 0.8 : 0), lineWidth: 1.5)
                            )
                            .contentShape(Circle().size(width: 28, height: 28))
                            .position(x: x, y: y)
                            .gesture(
                                TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { value in
                                    selected = index
                                    if case .first = value { resetBand(index) }
                                }
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("eqPlot")).onChanged { value in
                                    selected = index
                                    let fraction = min(1, max(0, (value.location.x - rect.minX) / rect.width))
                                    let gain = min(18, max(-18, (rect.midY - value.location.y) / rect.height * 36))
                                    model.edit(appID) {
                                        $0.bands[index].frequency = (20 * pow(upper / 20, fraction)).rounded()
                                        if $0.bands[index].type.hasGain {
                                            $0.bands[index].gain = (gain * 10).rounded() / 10
                                        }
                                    }
                                }
                            )
                            .accessibilityLabel(
                                "EQ band \(index + 1), \(Int(b.frequency)) Hz, \(b.gain, specifier: "%.1f") dB"
                            )
                            .accessibilityAction(named: "Reset band") { resetBand(index) }
                            .help("Drag to adjust. Double-click to reset this band.")
                            .contextMenu { Button("Reset band") { resetBand(index) } }
                    }
                }
            }.coordinateSpace(name: "eqPlot")
                .help(
                    "Frequency is logarithmic: equal distance means equal frequency ratio. Left axis: EQ gain. Right axis: actual output level. A −18 dB cut reduces amplitude by about 87%; it does not mute that frequency. The spectrum uses a 16,384-sample analysis window, separate from playback."
                )
        }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: isGlobal ? 0 : 6))
    }
    private var spectrumLayer: some View {
        ZStack {
            if processing, !telemetry.spectrum.isEmpty {
                SpectrumTrace(levels: SpectrumPlotValues(spectrum: telemetry.spectrum), filled: true)
                    .fill(Color.accentColor.opacity(0.16))
                    .animation(reduceMotion ? nil : .linear(duration: 0.033), value: telemetry.spectrum)
                    .id(telemetry.spectrum.count)
                if isGlobal {
                    ForEach(spectrumApps) { app in
                        let bins = model.telemetry.apps[app.id]?.spectrum ?? []
                        SpectrumTrace(levels: SpectrumPlotValues(spectrum: bins))
                            .stroke(model.spectrumColor(for: app).opacity(0.85), lineWidth: 1)
                            .animation(reduceMotion ? nil : .linear(duration: 0.033), value: bins)
                            .id(bins.count)
                    }
                }
            }
        }.accessibilityHidden(true)
    }

    private func resetBand(_ index: Int) {
        selected = index
        model.edit(appID) { $0.bands[index] = MixerSettings.defaultBands[index] }
    }
}
