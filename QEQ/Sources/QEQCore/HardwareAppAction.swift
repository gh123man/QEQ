import Foundation

public enum HardwareAppAction: Int, CaseIterable, Sendable {
    case boost, mute, volume, slot, back
    public func canActivate(mapped: Bool) -> Bool { self != .volume || !mapped }
    /// App gain uses percentage-point steps, with the same boost limits as QEQ.
    public static func adjustedVolume(_ value: Double, maximum: Double, steps: Int, mapped: Bool) -> Double? {
        guard !mapped else { return nil }
        let limit = maximum.isFinite ? min(2, max(1, maximum)) : 1
        let current = value.isFinite ? value : 1
        return min(limit, max(0, (current * 100).rounded() / 100 + Double(steps) / 100))
    }
}
