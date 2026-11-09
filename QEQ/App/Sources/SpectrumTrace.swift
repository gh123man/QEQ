import QEQAppSupport
import SwiftUI

/// Shared bin-centered trace geometry. SpectrumSurface interpolates its paths
/// in Core Animation; the grid, response and draggable handles stay static.
struct SpectrumTrace: Shape {
    var levels: SpectrumPlotValues
    var filled = false

    var animatableData: SpectrumPlotValues {
        get { levels }
        set { levels = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(levels.path(in: rect, filled: filled))
    }
}
