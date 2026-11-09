import QEQAppSupport
import QEQCore
import SwiftUI

struct HardwareCalibrationView: View {
    let service: HardwareMIDIService
    let source: UInt32
    let pair: UInt8
    @State private var calibration = HardwareCalibration()
    @State private var raw: Int?
    @State private var loaded = false
    @State private var busy = false
    @State private var polling = false
    @State private var status = "Reading controller…"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Slider \(pair) calibration").font(.headline)
            Text("Raw position: \(raw.map(String.init) ?? "—")").monospacedDigit()
            Text(
                "Move fully down and capture the bottom, then fully up and capture the top. Apply when both endpoints are set."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Capture bottom") { if let raw { calibration.minimum = raw } }
                Text("\(calibration.minimum)").monospacedDigit()
                Spacer()
                Button("Capture top") { if let raw { calibration.maximum = raw } }
                Text("\(calibration.maximum)").monospacedDigit()
            }.disabled(raw == nil || busy)
            Toggle("Reverse slider direction", isOn: $calibration.reversed)
            Stepper("Movement threshold: \(calibration.threshold) / 127", value: $calibration.threshold, in: 1...8)
            Stepper("Stable samples: \(calibration.confirmations)", value: $calibration.confirmations, in: 1...10)
            Stepper("Smoothing: \(calibration.smoothing)", value: $calibration.smoothing, in: 1...4)
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Restore defaults") { calibration = HardwareCalibration() }.disabled(busy)
                Spacer()
                Button("Apply") { apply() }.disabled(!loaded || busy || polling || !calibration.valid)
            }
        }.padding(24).frame(width: 460)
            .task {
                while !Task.isCancelled {
                    if !busy {
                        polling = true
                        let reading = await read()
                        polling = false
                        if let reading {
                            raw = reading.raw
                            if !loaded {
                                calibration = reading.calibration
                                loaded = true
                                status = "Ready"
                            }
                        } else {
                            raw = nil
                            status = "Controller unavailable; reconnect to continue."
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
    }
    private func read() async -> HardwareCalibrationReading? {
        await withCheckedContinuation { continuation in
            service.calibrate(source: source, pair: pair) { continuation.resume(returning: $0) }
        }
    }
    private func apply() {
        busy = true
        status = "Applying…"
        service.calibrate(source: source, pair: pair, setting: calibration) { reading in
            busy = false
            if let reading {
                calibration = reading.calibration
                raw = reading.raw
                status = "Verified and saved. QEQ will restore this after reconnecting."
            } else {
                status = "Not confirmed. Read the controller again before retrying."
            }
        }
    }
}
