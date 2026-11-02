import AppMixerCore
import SwiftUI

struct ParametricEQView: View {
    @ObservedObject var model: MixerModel
    let appID: String
    @State private var selected = 0
    private var settings: MixerSettings { model.value(appID) }
    private var band: EQBand { settings.bands[selected] }
    private var processing: Bool { model.enabled && settings.enabled && model.snapshot.active.contains(appID) }
    private var maxFrequency: Double { min(20000, model.snapshot.sampleRate * 0.45) }
    private let colors: [Color] = [.orange, .yellow, .teal, .blue, .purple]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("Parametric EQ").font(.system(size: 11, weight: .medium))
                Spacer()
                if processing && !model.telemetry.spectrum.isEmpty {
                    Circle().fill(.teal).frame(width: 5, height: 5)
                    Text("Live output").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(
                        model.telemetry.peak > 0.00003
                            ? String(format: "%.0f dBFS", 20 * log10(model.telemetry.peak)) : "−∞ dBFS"
                    )
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(
                        width: 53, alignment: .trailing)
                } else {
                    Text(processing ? "Waiting for signal" : "Preview · spectrum when processing").font(
                        .system(size: 9)
                    ).foregroundStyle(.secondary)
                }
            }
            graph.frame(height: 190)
            HStack(spacing: 5) {
                ForEach(0..<5) { index in
                    Button {
                        selected = index
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(settings.bands[index].enabled ? colors[index] : .secondary).frame(
                                width: 5, height: 5)
                            Text("\(index + 1)")
                        }.font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(
                                selected == index ? colors[index].opacity(0.16) : Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityLabel("Select EQ band \(index + 1)")
                }
            }
            HStack {
                Toggle("Band \(selected + 1)", isOn: binding(\.enabled)).toggleStyle(.checkbox).font(.system(size: 11))
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
                }.labelsHidden().frame(width: 125).controlSize(.small)
            }
            HStack(spacing: 12) {
                numberControl(
                    "Frequency", unit: "Hz", value: binding(\.frequency), range: 20...maxFrequency, decimals: 0)
                numberControl("Gain", unit: "dB", value: binding(\.gain), range: -18...18, decimals: 1).disabled(
                    !band.type.hasGain)
                numberControl(
                    band.type.isShelf ? "Slope" : "Q", unit: "", value: binding(\.q),
                    range: 0.1...(band.type.isShelf ? 1 : 10), decimals: 2)
            }
            HStack(spacing: 8) {
                Text("Width").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 35, alignment: .leading)
                Slider(
                    value: Binding(get: { log10(band.q) }, set: { value in edit { $0.q = pow(10, value) } }),
                    in: -1...(band.type.isShelf ? 0 : 1)
                )
                .accessibilityLabel(band.type.isShelf ? "Shelf slope" : "Band Q")
                Text(band.type.isShelf ? "Gentle → steep" : "Broad → narrow").font(.system(size: 9)).foregroundStyle(
                    .tertiary)
            }
            HStack {
                Menu("Presets") {
                    Button("Cut bass") {
                        model.edit(appID) {
                            $0.bands = MixerSettings.defaultBands
                            $0.bass = -12
                        }
                    }
                    Button("Voice clarity") {
                        model.edit(appID) {
                            $0.bands = MixerSettings.defaultBands
                            $0.bands[0] = EQBand(type: .highPass, frequency: 100)
                            $0.bands[3].gain = 3
                        }
                    }
                    Button("Flat EQ") { model.edit(appID) { $0.bands = MixerSettings.defaultBands } }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                let limiting = processing && model.telemetry.limitingDB > 0.1
                Text(limiting ? String(format: "Limiting −%.1f dB", model.telemetry.limitingDB) : "Peak protection")
                    .foregroundStyle(limiting ? Color.orange : Color.secondary)
                    .help(
                        "Only reduces gain when output peaks exceed full scale, with no added buffering. Lower app volume if limiting is frequent. The curve shows EQ before volume and peak protection."
                    )
                Button("Reset app") { model.edit(appID) { $0 = MixerSettings() } }
            }.font(.system(size: 10)).buttonStyle(.borderless)
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
            let rect = CGRect(x: 29, y: 14, width: geometry.size.width - 43, height: geometry.size.height - 37)
            let upper = maxFrequency
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.055, green: 0.067, blue: 0.078))
                Canvas { context, size in
                    func x(_ hz: Double) -> CGFloat { rect.minX + log(hz / 20) / log(upper / 20) * rect.width }
                    func y(_ db: Double) -> CGFloat { rect.midY - db / 36 * rect.height }
                    for db in [-18.0, -9, 0, 9, 18] {
                        var line = Path()
                        line.move(to: CGPoint(x: rect.minX, y: y(db)))
                        line.addLine(to: CGPoint(x: rect.maxX, y: y(db)))
                        context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.25 : 0.07)), lineWidth: 1)
                        context.draw(
                            Text(String(format: "%+.0f", db)).font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45)), at: CGPoint(x: 14, y: y(db)))
                    }
                    for hz in [20.0, 100, 1000, 10000, 20000] where hz <= upper {
                        var line = Path()
                        line.move(to: CGPoint(x: x(hz), y: rect.minY))
                        line.addLine(to: CGPoint(x: x(hz), y: rect.maxY))
                        context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 1)
                        let label = hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
                        context.draw(
                            Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(
                                .white.opacity(0.45)), at: CGPoint(x: x(hz), y: rect.maxY + 12))
                    }
                    if processing, !model.telemetry.spectrum.isEmpty {
                        let spectrum = model.telemetry.spectrum
                        var area = Path()
                        area.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        for (index, db) in spectrum.enumerated() {
                            area.addLine(
                                to: CGPoint(
                                    x: rect.minX + (Double(index) + 0.5) / Double(spectrum.count) * rect.width,
                                    y: rect.maxY - CGFloat(max(0, min(1, (db + 90) / 90))) * rect.height))
                        }
                        area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        area.closeSubpath()
                        context.fill(area, with: .color(.teal.opacity(0.16)))
                    }
                    var curve = Path()
                    for index in 0...240 {
                        let hz = 20 * pow(upper / 20, Double(index) / 240)
                        let db = settings.responseDB(at: hz, sampleRate: model.snapshot.sampleRate)
                        let point = CGPoint(x: x(hz), y: y(min(18, max(-18, db))))
                        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    context.stroke(
                        curve, with: .color(.white.opacity(processing ? 0.9 : 0.6)),
                        style: StrokeStyle(lineWidth: 1.6, dash: processing ? [] : [4, 3]))
                    context.draw(
                        Text("EQ dB · spectrum −90…0 dBFS").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4)),
                        at: CGPoint(x: rect.maxX - 4, y: rect.minY + 6), anchor: .topTrailing)
                }
                ForEach(0..<5) { index in
                    let b = settings.bands[index]
                    let x = rect.minX + log(min(upper, max(20, b.frequency)) / 20) / log(upper / 20) * rect.width
                    let y = rect.midY - (b.type.hasGain ? b.gain : 0) / 36 * rect.height
                    Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                        .frame(width: selected == index ? 21 : 17, height: selected == index ? 21 : 17)
                        .background(b.enabled ? colors[index] : .gray, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(selected == index ? 0.8 : 0), lineWidth: 1.5))
                        .contentShape(Circle().size(width: 28, height: 28))
                        .position(x: x, y: y)
                        .onTapGesture { selected = index }
                        .gesture(
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
                            "EQ band \(index + 1), \(Int(b.frequency)) Hz, \(b.gain, specifier: "%.1f") dB")
                }
            }.coordinateSpace(name: "eqPlot")
        }
    }
}
