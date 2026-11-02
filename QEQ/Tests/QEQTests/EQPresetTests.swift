import QEQCore
import Testing

@Test func presetsProduceTheirIntendedResponseAcrossSampleRates() {
    for rate in [44100.0, 48000, 96000] {
        func response(_ preset: EQPreset, _ frequency: Double) -> Double {
            var settings = MixerSettings()
            settings.bands = preset.bands
            return settings.responseDB(at: frequency, sampleRate: rate)
        }
        for preset in EQPreset.allCases {
            for frequency in [20.0, 60, 200, 1000, 3500, 10000, 20000] {
                #expect(response(preset, frequency).isFinite)
            }
        }
        #expect(abs(response(.flat, 1000)) < 0.01)
        #expect(response(.boostBass, 40) > 4)
        #expect(abs(response(.boostBass, 4000)) < 0.1)
        #expect(response(.soften, 3500) < -3)
        #expect(response(.scoop, 800) < -3.5)
        #expect(response(.rumble, 20) < -15)
        #expect(abs(response(.rumble, 1000)) < 0.1)
        #expect(response(.telephone, 60) < -20)
        #expect(response(.telephone, 10000) < -15)
        #expect(abs(response(.telephone, 1000)) < 0.5)
    }
}
