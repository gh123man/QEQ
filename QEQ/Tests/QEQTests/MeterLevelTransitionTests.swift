import QEQCore
import Testing

@Test func meterRisesQuicklyAndSettlesWithoutLingeringAtSilence() {
    var meter = MeterLevelTransition()
    meter.setTarget(1, at: 0, animated: true)
    #expect(meter.value(at: 0) == 0)
    #expect(abs(meter.value(at: 0.025) - 0.5) < 0.000001)
    #expect(meter.value(at: 0.05) == 1)
    #expect(meter.isSettled(at: 0.05))
    meter.setTarget(0, at: 1, animated: true)
    #expect(abs(meter.value(at: 1.04) - 0.5) < 0.000001)
    #expect(meter.value(at: 1.081) == 0)
    #expect(meter.isSettled(at: 1.081))
}

@Test func meterRetargetsContinuouslyAndRepeatedUpdatesDoNotRestartIt() {
    var meter = MeterLevelTransition()
    meter.setTarget(1, at: 0, animated: true)
    meter.setTarget(1, at: 0.02, animated: true)
    #expect(meter.isSettled(at: 0.05))
    let displayed = meter.value(at: 0.025)
    meter.setTarget(0.2, at: 0.025, animated: true)
    #expect(meter.value(at: 0.025) == displayed)
    #expect(meter.value(at: 0.06) < displayed && meter.value(at: 0.06) > 0.2)
    #expect(abs(meter.value(at: 1) - 0.2) < 0.000001)
}

@Test func meterSnapsForHiddenViewsBypassAndReducedMotion() {
    var meter = MeterLevelTransition()
    meter.setTarget(1, at: 0, animated: true)
    meter.setTarget(1, at: 0.01, animated: false)
    #expect(meter.value(at: 0.01) == 1 && meter.isSettled(at: 0.01))
    meter.setTarget(0, at: 0.02, animated: false)
    #expect(meter.value(at: 0.02) == 0 && meter.isSettled(at: 0.02))
}
