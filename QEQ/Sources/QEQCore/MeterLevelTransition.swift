import Foundation

/// Short visual interpolation only; audio and telemetry are never delayed.
public struct MeterLevelTransition {
    public private(set) var target: Double = 0
    private var start: Double = 0
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0

    public init() {}

    public func value(at time: TimeInterval) -> Double {
        guard duration > 0 else { return target }
        let progress = max(0, min(1, (time - startTime) / duration))
        return start + (target - start) * progress
    }

    public func isSettled(at time: TimeInterval) -> Bool {
        duration == 0 || time >= startTime + duration
    }

    public mutating func setTarget(_ level: Double, at time: TimeInterval, animated: Bool) {
        let level = level.isFinite ? min(1, max(0, level)) : 0
        guard animated else {
            start = level
            target = level
            duration = 0
            return
        }
        // Repeated SwiftUI updates must not restart an in-flight transition.
        guard level != target else { return }
        start = value(at: time)
        target = level
        startTime = time
        duration = target == start ? 0 : (target > start ? 0.05 : 0.08)
    }
}
