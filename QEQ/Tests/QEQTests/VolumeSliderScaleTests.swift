import Foundation
import QEQCore
import Testing

@Test func boostUsesFinalFifthOfSliderWithEqualDecibelSteps() {
    let scale = VolumeSliderScale(maximum: 2)
    #expect(scale.gain(at: 0) == 0)
    #expect(scale.gain(at: 0.4) == 0.5)
    #expect(scale.gain(at: 0.8) == 1)
    #expect(abs(scale.gain(at: 0.9) - sqrt(2)) < 0.000001)
    #expect(scale.gain(at: 1) == 2)
    let lowerDB = 20 * log10(scale.gain(at: 0.9) / scale.gain(at: 0.8))
    let upperDB = 20 * log10(scale.gain(at: 1) / scale.gain(at: 0.9))
    #expect(abs(lowerDB - upperDB) < 0.000001)
}

@Test func volumeScalePreservesSavedGainAndUnboostedTravel() {
    for maximum in [1.0, 2] {
        let scale = VolumeSliderScale(maximum: maximum)
        var previous = -1.0
        for step in 0...200 {
            let position = Double(step) / 200
            let gain = scale.gain(at: position)
            #expect(gain > previous)
            #expect(abs(scale.position(for: gain) - position) < 0.000001)
            if maximum == 1 { #expect(gain == position) }
            previous = gain
        }
        #expect(scale.gain(at: scale.unityPosition) == 1)
    }
    // Toggling Boost moves the handle without changing any gain below unity.
    let normal = VolumeSliderScale(maximum: 1)
    let boosted = VolumeSliderScale(maximum: 2)
    for gain in [0.0, 0.25, 0.65, 1] {
        #expect(abs(normal.gain(at: normal.position(for: gain)) - gain) < 0.000001)
        #expect(abs(boosted.gain(at: boosted.position(for: gain)) - gain) < 0.000001)
    }
}
