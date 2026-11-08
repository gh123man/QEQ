import Testing

@testable import QEQAppSupport

@Test @MainActor func systemVolumeStepsClampAndPreserveChannelBalance() {
    let stereo = SystemOutputVolume.adjusted([0.5, 0.25], steps: 8)
    #expect(stereo == [0.625, 0.3125])
    #expect(SystemOutputVolume.adjusted(stereo, steps: -8) == [0.5, 0.25])
    #expect(SystemOutputVolume.adjusted([0.5, 0.25], steps: 1000) == [1, 0.5])
    #expect(SystemOutputVolume.adjusted([0.5, 0.25], steps: -1000) == [0, 0])
    #expect(SystemOutputVolume.adjusted([0, 0], steps: 1) == [0.015625, 0.015625])
    #expect(SystemOutputVolume.adjusted([0.5, 0], steps: 1) == [0.515625, 0])
    #expect(SystemOutputVolume.adjusted([0.5], steps: 1) == [0.515625])
    #expect(SystemOutputVolume.adjusted([], steps: 1).isEmpty)
}
