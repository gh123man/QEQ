import AppMixerCore
// Aggregate topology and stream-usage setup adapted from CoreAudioTapKit (MIT).
// See THIRD_PARTY_NOTICES.md. All lifecycle calls run on MixerEngine's serial queue.
import CoreAudio
import Foundation
import MixerDSP

final class AppAudioRoute: AudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    let processes: [AudioObjectID]
    let output: OutputDevice
    private(set) var lastFrames: UInt64 = 0
    private(set) var lastProgress = ProcessInfo.processInfo.systemUptime

    init(app: AudioApplication, output: OutputDevice, settings: MixerSettings, global: MixerSettings = MixerSettings())
        throws
    {
        processes = app.processes
        self.output = output
        try start(app: app, settings: settings, global: global)
    }

    private func start(app: AudioApplication, settings: MixerSettings, global: MixerSettings) throws {
        do {
            let description = CATapDescription(processes: app.processes, deviceUID: output.uid, stream: 0)
            description.name = "QEQ · \(app.name)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try checkAudio(AudioHardwareCreateProcessTap(description, &tap), "Create app audio tap")
            let format = try HAL.format(tap, kAudioTapPropertyFormat)
            try HAL.validate(format)
            guard format.mSampleRate == output.sampleRate, format.mChannelsPerFrame == output.channels else {
                throw AudioFailure(
                    message: "The app tap and output formats do not match. Select another output and retry.")
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "QEQ · \(app.name)",
                kAudioAggregateDeviceUIDKey: "local.AppMixer.route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality,
                    ]
                ],
            ]
            try checkAudio(
                AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create private audio route")
            var alive = false
            for _ in 0..<30 {
                if (try? HAL.uint(aggregate, kAudioDevicePropertyDeviceIsAlive)) == 1 {
                    alive = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard alive else {
                throw AudioFailure(message: "The output device did not become ready. System audio has been restored.")
            }
            let physicalInputs = try HAL.objects(
                output.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
            ).count
            let totalInputs = try HAL.objects(
                aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
            ).count
            guard totalInputs > physicalInputs else {
                throw AudioFailure(message: "Core Audio did not attach the app's audio stream.")
            }
            let buffers = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? format.mChannelsPerFrame : 1
            guard let processor = MixerDSPCreate(format.mSampleRate, format.mChannelsPerFrame, buffers) else {
                throw AudioFailure(message: "Unsupported audio format.")
            }
            dsp = processor
            update(settings, global: global)
            try checkAudio(MixerDSPRegister(aggregate, processor, &proc), "Create realtime processor")
            // Strictly disable physical input streams BEFORE starting; never request microphone access.
            if physicalInputs > 0 { try disablePhysicalInputs(physicalInputs, total: totalInputs) }
            try checkAudio(AudioDeviceStart(aggregate, proc), "Start app processing")
        } catch {
            stop()
            throw error
        }
    }
    func update(_ settings: MixerSettings, global: MixerSettings) {
        if let dsp {
            let bands = settings.processingBands(global: global)
            bands.withUnsafeBufferPointer {
                MixerDSPConfigure(
                    dsp, settings.enabled ? Float(settings.volume) : 1,
                    settings.enabled && settings.muted, $0.baseAddress, UInt32($0.count))
            }
        }
    }
    func setAnalysis(_ enabled: Bool) { if let dsp { MixerDSPEnableAnalysis(dsp, enabled) } }
    func analysis(using analyzer: SpectrumAnalyzer) -> AudioTelemetry? {
        guard let dsp else { return nil }
        return analyzer.read(dsp: dsp, sampleRate: output.sampleRate)
    }
    var peak: Float { dsp.map { MixerDSPPeak($0) } ?? 0 }
    func checkHealth() throws {
        guard let dsp else { return }
        let frames = MixerDSPFrames(dsp)
        if frames != lastFrames {
            lastFrames = frames
            lastProgress = ProcessInfo.processInfo.systemUptime
        }
        if MixerDSPFaults(dsp) > 0 {
            throw AudioFailure(
                message:
                    "The output buffer layout changed. Processing stopped to restore normal audio. Retry the mixer.")
        }
        if (ProcessInfo.processInfo.systemUptime - lastProgress) > 4 {
            throw AudioFailure(
                message:
                    "No audio callbacks arrived while this app reported active playback. The app route has been released. This can be a device/route problem or capture access; it does not by itself establish a permission failure."
            )
        }
    }
    func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
        if tap != 0 {
            AudioHardwareDestroyProcessTap(tap)
            tap = 0
        }
        if let dsp {
            MixerDSPDestroy(dsp)
            self.dsp = nil
        }
    }
    deinit { stop() }

    private func disablePhysicalInputs(_ physical: Int, total: Int) throws {
        guard let proc else { return }
        var address = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try checkAudio(
            AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size), "Inspect audio input streams")
        guard Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size else {
            throw AudioFailure(message: "Cannot isolate app audio from hardware inputs on this device.")
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        try checkAudio(
            AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, usage), "Inspect audio input streams")
        guard Int(usage.pointee.mNumberStreams) == total,
            let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn),
            Int(size) >= offset + total * MemoryLayout<UInt32>.size
        else {
            throw AudioFailure(message: "Cannot safely disable hardware input streams on this device.")
        }
        let flags = raw.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<total { flags[index] = index < physical ? 0 : 1 }
        try checkAudio(
            AudioObjectSetPropertyData(aggregate, &address, 0, nil, size, usage), "Disable hardware input streams")
    }
}
