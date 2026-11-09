import SwiftUI

/// Animatable vertical positions on the existing −90…0 dBFS plot scale.
/// Interpolation changes presentation only, never the measured spectrum bins.
public struct SpectrumPlotValues: VectorArithmetic, Sendable {
    public private(set) var values: [Double]

    public init(spectrum: [Float]) {
        values = spectrum.map { $0.isFinite ? Double(max(0, min(1, ($0 + 90) / 90))) : 0 }
    }

    init(values: [Double]) { self.values = values }
    /// Shared bin-centered geometry for the app and the hardware display.
    public func path(in rect: CGRect, filled: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard !values.isEmpty else { return path }
        if filled { path.move(to: CGPoint(x: rect.minX, y: rect.maxY)) }
        for (index, level) in values.enumerated() {
            let point = CGPoint(
                x: rect.minX + (Double(index) + 0.5) / Double(values.count) * rect.width,
                y: rect.maxY - max(0, min(1, level)) * rect.height)
            if !filled && index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if filled {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    public static let zero = Self(values: [])

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            values: (0..<max(lhs.values.count, rhs.values.count)).map {
                (lhs.values.indices.contains($0) ? lhs.values[$0] : 0)
                    + (rhs.values.indices.contains($0) ? rhs.values[$0] : 0)
            })
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            values: (0..<max(lhs.values.count, rhs.values.count)).map {
                (lhs.values.indices.contains($0) ? lhs.values[$0] : 0)
                    - (rhs.values.indices.contains($0) ? rhs.values[$0] : 0)
            })
    }

    public mutating func scale(by rhs: Double) {
        for index in values.indices { values[index] *= rhs }
    }

    public var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
