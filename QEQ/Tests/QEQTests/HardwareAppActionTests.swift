import QEQCore
import Testing

@Test func appActionsKeepOrderAndLockOnlyMappedVolume() {
    #expect(HardwareAppAction.allCases == [.boost, .mute, .volume, .slot, .back])
    for action in HardwareAppAction.allCases {
        #expect(action.canActivate(mapped: false))
        #expect(action.canActivate(mapped: true) == (action != .volume))
    }
}
@Test func dialVolumeUsesPercentStepsAndRechecksSliderOwnership() {
    #expect(HardwareAppAction.adjustedVolume(0.5, maximum: 1, steps: 1, mapped: false) == 0.51)
    #expect(HardwareAppAction.adjustedVolume(0.5, maximum: 1, steps: -1, mapped: false) == 0.49)
    #expect(HardwareAppAction.adjustedVolume(0.01, maximum: 1, steps: -5, mapped: false) == 0)
    #expect(HardwareAppAction.adjustedVolume(0.99, maximum: 1, steps: 5, mapped: false) == 1)
    #expect(HardwareAppAction.adjustedVolume(1.99, maximum: 2, steps: 5, mapped: false) == 2)
    #expect(HardwareAppAction.adjustedVolume(1, maximum: 2, steps: 1, mapped: false) == 1.01)
    for steps in [-63, -1, 0, 1, 63] {
        #expect(HardwareAppAction.adjustedVolume(0.5, maximum: 2, steps: steps, mapped: true) == nil)
    }
}
