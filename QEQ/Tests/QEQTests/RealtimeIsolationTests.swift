import CoreAudio
import Dispatch
import Foundation
import MixerDSP
import Testing

/// One audio writer and one analysis reader, matching the production contract.
/// The test joins the reader before destroying the processor.
private final class SharedProcessor: @unchecked Sendable {
    let pointer: OpaquePointer
    init() { pointer = MixerDSPCreate(48000, 2, 1)! }
    deinit { MixerDSPDestroy(pointer) }
}

@Test func concurrentAndStalledSpectrumReadsCannotAlterAudio() {
    let dsp = SharedProcessor()
    MixerDSPEnableAnalysis(dsp.pointer, true)
    let reader = DispatchGroup()
    let started = DispatchSemaphore(value: 0)
    reader.enter()
    DispatchQueue(label: "QEQ.test.spectrum-reader").async {
        var left = [Float](repeating: 0, count: Int(MixerAnalysisFrameCount))
        var right = left
        started.signal()
        for index in 0..<500 {
            _ = MixerDSPReadAnalysis(dsp.pointer, &left, &right, UInt32(left.count))
            // A stalled analyzer/UI consumer must not hold up the producer.
            if index.isMultiple(of: 20) { Thread.sleep(forTimeInterval: 0.001) }
        }
        reader.leave()
    }
    started.wait()  // Test setup only; never inside the simulated callback.
    let frames = 64
    var input = (0..<(frames * 2)).map { Float(0.2 * sin(Double($0) * 0.17)) }
    var output = [Float](repeating: 0, count: input.count)
    var mismatches = 0
    input.withUnsafeMutableBytes { source in
        output.withUnsafeMutableBytes { destination in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(source.count), mData: source.baseAddress))
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(destination.count), mData: destination.baseAddress))
            for _ in 0..<10_000 {
                MixerDSPProcess(dsp.pointer, &inABL, &outABL)
                if memcmp(source.baseAddress!, destination.baseAddress!, source.count) != 0 { mismatches += 1 }
            }
        }
    }
    reader.wait()
    #expect(mismatches == 0)
    #expect(MixerDSPFrames(dsp.pointer) == UInt64(frames * 10_000))
    #expect(MixerDSPFaults(dsp.pointer) == 0)
}
