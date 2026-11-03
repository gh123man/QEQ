import QEQAppSupport
import SwiftUI

/// SwiftUI interpolates only this inexpensive trace. Grid, filter response and
/// draggable EQ handles stay outside the per-frame animation work.
struct SpectrumTrace: Shape {
    var levels: SpectrumPlotValues
    var filled = false

    var animatableData: SpectrumPlotValues {
        get { levels }
        set { levels = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !levels.values.isEmpty else { return path }
        if filled { path.move(to: CGPoint(x: rect.minX, y: rect.maxY)) }
        for (index, level) in levels.values.enumerated() {
            let point = CGPoint(
                x: rect.minX + (Double(index) + 0.5) / Double(levels.values.count) * rect.width,
                y: rect.maxY - max(0, min(1, level)) * rect.height)
            if !filled && index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if filled {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
