import Combine
import QEQAppSupport
import QEQCore
import SwiftUI

// Only these small leaves observe the 30 Hz telemetry stream. Their parent
// layout, controls and static graph canvases are independent of audio frames.

struct LiveSpectrumStatus: View {
    let liveAudio: LiveAudioTelemetry
    let appID: String
    let processing: Bool
    @State private var status = AudioDisplayStatus()
    let compact: Bool
    var body: some View {
        HStack(spacing: 5) {
            Spacer()
            if processing && status.hasSpectrum {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                if status.simulated {
                    Text("Simulated spectrum").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if compact && status.limiting != nil {
                    Text(status.limiting ?? "")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange)
                        .help(
                            "Automatic clipping protection is reducing gain. Lower app volume or EQ boosts for more headroom."
                        )
                } else {
                    Text(status.peak)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(
                            width: 53, alignment: .trailing)
                }
            } else {
                Text(processing ? "Waiting for signal" : "Preview · enable processing for spectrum").font(
                    .system(size: 9)
                ).foregroundStyle(.secondary)
            }
        }
        .onReceive(liveAudio.$value.map { AudioDisplayStatus($0, appID: appID) }.removeDuplicates()) {
            status = $0
        }
    }
}

struct LiveLimitingStatus: View {
    let liveAudio: LiveAudioTelemetry
    let appID: String
    let processing: Bool
    @State private var limiting: String?
    var body: some View {
        Group {
            if processing && limiting != nil {
                Label(
                    limiting ?? "",
                    systemImage: "waveform.badge.minus"
                )
                .foregroundStyle(Color.orange)
                .help(
                    "Automatic clipping protection is reducing output gain by this amount. Lower app volume or EQ boosts if this happens often. The EQ curve is shown before volume and limiting."
                )
            }
        }
        .onReceive(liveAudio.$value.map { AudioDisplayStatus($0, appID: appID).limiting }.removeDuplicates()) {
            limiting = $0
        }
    }
}

struct LiveSpectrumLayer: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let liveAudio: LiveAudioTelemetry
    let appID: String
    let processing: Bool
    let apps: [(id: String, color: Color)]

    func makeNSView(context: Context) -> SpectrumSurface {
        let view = SpectrumSurface()
        view.observe(liveAudio)
        return view
    }

    func updateNSView(_ view: SpectrumSurface, context: Context) {
        view.configure(
            appID: appID, processing: processing, apps: apps.map { ($0.id, NSColor($0.color)) },
            accent: NSColor(Color.accentColor), animated: !reduceMotion)
    }

    static func dismantleNSView(_ view: SpectrumSurface, coordinator: ()) { view.stopObserving() }
}

struct LiveAppMeter: View {
    let liveAudio: LiveAudioTelemetry
    let appID: String
    @Binding var value: Double
    let maximum: Double
    let metered: Bool
    let muted: Bool
    let bypassed: Bool
    let color: NSColor
    let appName: String

    var body: some View {
        InsetMeterSlider(
            value: $value, maximum: maximum,
            metered: metered, muted: muted, bypassed: bypassed, color: color, appName: appName,
            liveAudio: liveAudio, appID: appID
        )
    }
}
