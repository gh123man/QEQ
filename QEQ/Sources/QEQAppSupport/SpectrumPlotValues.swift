import SwiftUI

/// Animatable vertical positions on the existing −90…0 dBFS plot scale.
/// Interpolation changes presentation only, never the measured spectrum bins.
public struct SpectrumPlotValues: VectorArithmetic, Sendable {
    public private(set) var values: [Double]

    public init(spectrum: [Float]) {
        values = spectrum.map { $0.isFinite ? Double(max(0, min(1, ($0 + 90) / 90))) : 0 }
    }

    private init(values: [Double]) { self.values = values }
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
