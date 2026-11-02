import AppKit
import CoreAudio
import Foundation

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw AudioFailure(
            message:
                "\(operation) failed (Core Audio \(status)). If access was denied, allow QEQ in System Settings → Privacy & Security → Screen & System Audio Recording, then retry."
        )
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func uint(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var a = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try checkAudio(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "Read audio property")
        return value
    }
    static func double(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> Double {
        var a = address(selector)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        try checkAudio(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "Read sample rate")
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        try checkAudio(status, "Read audio name")
        return value as String
    }
    static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "List audio objects")
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!)
        }
        try checkAudio(status, "List audio objects")
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws
        -> AudioStreamBasicDescription
    {
        var a = address(selector)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkAudio(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "Read audio format")
        return value
    }
    static func validate(_ f: AudioStreamBasicDescription) throws {
        guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            f.mBitsPerChannel == 32, (1...2).contains(f.mChannelsPerFrame), f.mSampleRate >= 8000
        else {
            throw AudioFailure(
                message:
                    "This output format is not supported yet. Use a mono or stereo Float32 output, such as the built-in speakers or headphones."
            )
        }
    }
    static func output() throws -> OutputDevice {
        let id = try uint(system, kAudioHardwarePropertyDefaultOutputDevice)
        guard id != 0 else { throw AudioFailure(message: "No system audio output is available.") }
        let streams = try objects(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard streams.count == 1 else {
            throw AudioFailure(
                message:
                    "This version supports outputs with one mono or stereo stream. Select built-in speakers or headphones in macOS Sound settings."
            )
        }
        let format = try format(streams[0], kAudioStreamPropertyVirtualFormat)
        try validate(format)
        return OutputDevice(
            id: id, uid: try string(id, kAudioDevicePropertyDeviceUID), name: try string(id, kAudioObjectPropertyName),
            sampleRate: format.mSampleRate, bufferFrames: try uint(id, kAudioDevicePropertyBufferFrameSize),
            channels: format.mChannelsPerFrame)
    }
    static func applications(identityCache: AppIdentityCache? = nil) throws -> [AudioApplication] {
        let processes = try objects(system, kAudioHardwarePropertyProcessObjectList)
        identityCache?.retain(processes: processes)
        let now = ProcessInfo.processInfo.systemUptime
        var grouped: [String: AudioApplication] = [:]
        let runningApps = NSWorkspace.shared.runningApplications
        for object in processes {
            guard let rawPID = try? uint(object, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: rawPID)
            guard pid != getpid(), pid > 0 else { continue }
            let processBundle = (try? string(object, kAudioProcessPropertyBundleID)) ?? ""
            func resolve() -> AppIdentity {
                let running = NSRunningApplication(processIdentifier: pid)
                return AppIdentity.resolve(
                    bundleURL: running?.bundleURL, executableURL: running?.executableURL,
                    bundleID: running?.bundleIdentifier ?? (processBundle.isEmpty ? "pid.\(pid)" : processBundle),
                    fallbackName: running?.localizedName
                        ?? (processBundle.isEmpty ? "Audio process \(pid)" : processBundle), runningApps: runningApps)
            }
            let identity =
                identityCache?.identity(
                    object: object, pid: pid, bundleID: processBundle, now: now, resolve: resolve) ?? resolve()
            let key = identity.id
            let name = identity.name
            let url = identity.url
            guard key != Bundle.main.bundleIdentifier else { continue }
            let playing = ((try? uint(object, kAudioProcessPropertyIsRunningOutput)) ?? 0) != 0
            guard playing || url != nil else { continue }
            let devices: Set<AudioObjectID>? =
                playing
                ? (try? Set(objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))) : []
            if var app = grouped[key] {
                app.processes.append(object)
                app.playing = app.playing || playing
                if let previous = app.outputDevices, let devices {
                    app.outputDevices = previous.union(devices)
                } else {
                    app.outputDevices = nil
                }
                if !processBundle.isEmpty && processBundle != key && !app.aliases.contains(processBundle) {
                    app.aliases.append(processBundle)
                }
                grouped[key] = app
            } else {
                grouped[key] = AudioApplication(
                    id: key, name: name.isEmpty ? "Audio process \(pid)" : name, path: url?.path, processes: [object],
                    playing: playing, aliases: processBundle.isEmpty || processBundle == key ? [] : [processBundle],
                    outputDevices: devices)
            }
        }
        return grouped.values.map {
            var app = $0
            app.processes.sort()
            return app
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public struct AudioApplication: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String?
    public var processes: [AudioObjectID]
    public var playing: Bool
    public var aliases: [String] = []
    public var outputDevices: Set<AudioObjectID>? = nil
    public init(
        id: String, name: String, path: String? = nil, processes: [AudioObjectID] = [], playing: Bool = false,
        aliases: [String] = [], outputDevices: Set<AudioObjectID>? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.processes = processes
        self.playing = playing
        self.aliases = aliases
        self.outputDevices = outputDevices
    }
}
struct OutputDevice: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let sampleRate: Double
    let bufferFrames: UInt32
    let channels: UInt32
}
