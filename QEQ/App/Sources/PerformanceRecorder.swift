import AppKit
import Darwin
import Foundation

/// Opt-in process counters only: no audio, screen capture, or extra permissions.
/// Opens/closes our own popover to compare visible and background work.
@MainActor
final class PerformanceRecorder {
    private var timer: Timer?
    private var file: FileHandle?
    private var previousCPU = 0.0
    private var previousTime = 0.0
    private var tick = 0

    func start(path: String, model: MixerModel, isVisible: @escaping () -> Bool, setVisible: @escaping (Bool) -> Void) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
            let file = FileHandle(forWritingAtPath: path)
        else {
            NSLog("QEQ could not create profiling log at %@", path)
            return
        }
        self.file = file
        previousCPU = cpuTime()
        previousTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let cpu = self.cpuTime()
                let row: [String: Any] = [
                    "seconds": (self.tick + 1) * 2,
                    "cpuPercent": 100 * (cpu - self.previousCPU) / (now - self.previousTime),
                    "panelVisible": isVisible(),
                    "activeRoutes": model.snapshot.active.count,
                    "playingApps": model.snapshot.apps.filter(\.playing).count,
                    "latestPeak": model.snapshot.peaks.values.max() ?? 0,
                    "warmup": self.tick == 0 || self.tick == 5 || self.tick == 10,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                    try? self.file?.write(contentsOf: data + Data([10]))
                }
                self.previousCPU = cpu
                self.previousTime = now
                self.tick += 1
                if self.tick == 5 { setVisible(false) }
                if self.tick == 10 { setVisible(true) }
                if self.tick == 15 {
                    self.timer?.invalidate()
                    self.timer = nil
                    try? self.file?.close()
                    self.file = nil
                }
            }
        }
    }
    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
