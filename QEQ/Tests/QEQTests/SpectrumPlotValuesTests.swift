import QEQAppSupport
import Testing

@Test func spectrumAnimationPreservesDBScaleAndExactTargets() {
    let before = SpectrumPlotValues(spectrum: [-90, -60, -30, 0])
    let after = SpectrumPlotValues(spectrum: [-90, -78, -48, -18])
    var delta = after - before
    delta.scale(by: 0.5)
    let halfway = before + delta
    for index in before.values.indices {
        #expect(abs(halfway.values[index] - (before.values[index] + after.values[index]) / 2) < 0.000001)
    }
    let settled = before + (after - before)
    for index in after.values.indices {
        #expect(abs(settled.values[index] - after.values[index]) < 0.000001)
    }
    #expect(before.values[0] == 0 && before.values[3] == 1)
    #expect(abs(after.values[3] - 0.8) < 0.000001)  // −18 dB still has energy.
}

@Test func spectrumAnimationSupportsZeroAndSilenceWithoutOvershoot() {
    let live = SpectrumPlotValues(spectrum: [-20, -40, -60])
    #expect(live + .zero == live)
    #expect(live - .zero == live)
    let silence = SpectrumPlotValues(spectrum: [-90, -90, -90])
    for step in 0...10 {
        var delta = silence - live
        delta.scale(by: Double(step) / 10)
        let frame = live + delta
        for index in frame.values.indices {
            #expect(frame.values[index] >= -0.000001 && frame.values[index] <= live.values[index])
        }
    }
    #expect(silence.magnitudeSquared == 0)
    #expect(SpectrumPlotValues(spectrum: [.nan, -.infinity, -120, 4]).values == [0, 0, 0, 1])
}
