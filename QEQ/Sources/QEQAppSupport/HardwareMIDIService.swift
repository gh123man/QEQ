import CoreMIDI
import Foundation
import QEQCore

/// CoreMIDI owns delivery threads; parsing and all client callbacks run on MainActor.
@MainActor
public final class HardwareMIDIService {
    public struct Device: Equatable, Sendable {
        public let source: MIDIEndpointRef
        public let identity: QEQHardwareIdentity
        public let capabilities: HardwareCapabilities?
    }
    private struct Connection {
        var port: MIDIPortRef
        var destination: MIDIEndpointRef
        var generation: UUID
        var decoder = MIDIStreamDecoder()
        var identity: QEQHardwareIdentity?
        var capabilities: HardwareCapabilities?
        var restored = false
        var lastLEDs: [[UInt8]] = []
        var lastSeen = Date.distantPast
        var lastBytes = Date.distantPast
        var lastFeedback: [UInt8]?
    }
    public var onDevicesChanged: (([Device]) -> Void)?
    public var onMessage: ((MIDIEndpointRef, MIDIMessage) -> Void)?
    public var feedback: ((Device) -> [UInt8])?
    public var ledFeedback: ((Device) -> [[UInt8]])?
    public var onCalibrationChanged: ((MIDIEndpointRef, UInt8) -> Void)?
    private struct Pending {
        let source: MIDIEndpointRef
        let boot: [UInt8]
        let pair: UInt8
        let setting: HardwareCalibration?
        let completion: (HardwareCalibrationReading?) -> Void
    }
    private var pending: [UInt32: Pending] = [:]
    private var mediaPending: [UInt32: (MIDIEndpointRef, (Bool) -> Void)] = [:]
    private var token = UInt32.random(in: 0..<(1 << 28))
    private func nextToken() -> UInt32 {
        token = (token + 1) & 0x0FFF_FFFF
        return token
    }
    private func calibrationKey(_ serial: String, _ pair: UInt8) -> String { "hardwareCalibration.\(serial).\(pair)" }
    public func calibrate(
        source: MIDIEndpointRef, pair: UInt8, setting: HardwareCalibration? = nil,
        completion: @escaping (HardwareCalibrationReading?) -> Void
    ) {
        guard let connection = connections[source], let identity = connection.identity,
            connection.capabilities?.hasCalibration == true,
            connection.capabilities?.pairs.contains(where: { $0.id == pair }) == true,
            !pending.values.contains(where: { $0.source == source && $0.pair == pair })
        else {
            completion(nil)
            return
        }
        let token = nextToken()
        guard let bytes = identity.calibration(pair: pair, token: token, setting: setting), output != 0 else {
            completion(nil)
            return
        }
        pending[token] = Pending(
            source: source, boot: identity.boot, pair: pair, setting: setting, completion: completion)
        if setting != nil { onCalibrationChanged?(source, pair) }
        guard send(bytes, to: connection.destination) else {
            pending.removeValue(forKey: token)?.completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.pending.removeValue(forKey: token)?.completion(nil)
        }
    }
    public func sendMedia(
        _ command: HardwareMediaCommand, source: MIDIEndpointRef, completion: @escaping (Bool) -> Void
    ) {
        sendConsumerControl(usage: command.rawValue, source: source, completion: completion)
    }
    /// Generic Consumer-page output; adding software media actions needs no firmware command enum.
    public func sendConsumerControl(
        usage: UInt16, source: MIDIEndpointRef, completion: @escaping (Bool) -> Void
    ) {
        guard mediaPending.values.filter({ $0.0 == source }).count < 4 else {
            completion(false)
            return
        }
        guard let connection = connections[source], connection.capabilities?.hasMediaKeys == true,
            let identity = connection.identity, output != 0
        else {
            completion(false)
            return
        }
        let token = nextToken()
        guard let bytes = identity.consumerControl(usage: usage, token: token) else {
            completion(false)
            return
        }
        mediaPending[token] = (source, completion)
        guard send(bytes, to: connection.destination) else {
            mediaPending.removeValue(forKey: token)?.1(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.mediaPending.removeValue(forKey: token)?.1(false)
        }
    }
    public private(set) var status = "No QEQ controller connected"
    private var client: MIDIClientRef = 0
    private var output: MIDIPortRef = 0
    private var connections: [MIDIEndpointRef: Connection] = [:]
    private var timer: Timer?
    private var feedbackWork: DispatchWorkItem?
    private var heartbeatInterval: TimeInterval = 0.5
    private var testCandidates: (() -> [(MIDIEndpointRef, MIDIEndpointRef)])?
    public init() {}
    // Virtual endpoints exercise the real CoreMIDI callbacks without a physical USB entity.
    init(candidates: @escaping () -> [(MIDIEndpointRef, MIDIEndpointRef)], heartbeatInterval: TimeInterval = 0.5) {
        testCandidates = candidates
        self.heartbeatInterval = heartbeatInterval
    }
    public var devices: [Device] {
        connections.compactMap { source, connection in
            connection.identity.map { Device(source: source, identity: $0, capabilities: connection.capabilities) }
        }.sorted { $0.source < $1.source }
    }
    public func start() {
        guard client == 0 else { return }
        let result = MIDIClientCreateWithBlock("QEQ Hardware" as CFString, &client) { @Sendable [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        guard result == noErr else {
            status = "MIDI unavailable (\(result))"
            return
        }
        let resultOut = MIDIOutputPortCreate(client, "QEQ Feedback" as CFString, &output)
        guard resultOut == noErr else {
            MIDIClientDispose(client)
            client = 0
            status = "MIDI output unavailable (\(resultOut))"
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    public func stop() {
        let abandoned = pending
        pending = [:]
        for item in abandoned.values { item.completion(nil) }
        let media = mediaPending
        mediaPending = [:]
        for item in media.values { item.1(false) }
        timer?.invalidate()
        timer = nil
        feedbackWork?.cancel()
        feedbackWork = nil
        for connection in connections.values { MIDIPortDispose(connection.port) }
        connections = [:]
        if output != 0 {
            MIDIPortDispose(output)
            output = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
        changed()
    }
    public func reconnect() {
        stop()
        start()
    }
    /// Send the latest state on the next 16 ms control update, independently of heartbeat.
    public func requestFeedback() {
        guard client != 0, feedbackWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.feedbackWork = nil
            self.sendFeedback(force: false)
        }
        feedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
    }
    private func changed() {
        status =
            devices.isEmpty
            ? (connections.isEmpty ? "No QEQ controller connected" : "Waiting for compatible QEQ firmware")
            : "\(devices.count) QEQ controller(s) connected"
        onDevicesChanged?(devices)
    }
    private func refresh() {
        guard client != 0 else { return }
        var sources = Set<MIDIEndpointRef>()
        for (source, destination) in candidates() {
            sources.insert(source)
            if let old = connections[source], old.destination == destination { continue }
            if let old = connections.removeValue(forKey: source) { MIDIPortDispose(old.port) }
            var port: MIDIPortRef = 0
            let generation = UUID()
            let result = MIDIInputPortCreateWithBlock(client, "QEQ Input" as CFString, &port) {
                @Sendable [weak self] list, _ in
                let (copied, dropped) = Self.copyPacketBytes(list)
                DispatchQueue.main.async {
                    self?.receive(copied, source: source, generation: generation, overflow: dropped)
                }
            }
            guard result == noErr else { continue }
            guard MIDIPortConnectSource(port, source, nil) == noErr else {
                MIDIPortDispose(port)
                continue
            }
            connections[source] = Connection(port: port, destination: destination, generation: generation)
        }
        for source in Array(connections.keys) where !sources.contains(source) {
            if let old = connections.removeValue(forKey: source) { MIDIPortDispose(old.port) }
        }
        changed()
    }
    private func candidates() -> [(MIDIEndpointRef, MIDIEndpointRef)] {
        if let testCandidates { return testCandidates() }
        return (0..<MIDIGetNumberOfSources()).compactMap { index in
            let source = MIDIGetSource(index)
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(source, kMIDIPropertyName, &name) == noErr else { return nil }
            let title = name?.takeRetainedValue() as String? ?? ""
            // A name is only a discovery hint. A validated version/profile handshake is required.
            guard title.contains("QEQ Test Board") else { return nil }
            var entity: MIDIEntityRef = 0
            guard MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0,
                MIDIEntityGetNumberOfDestinations(entity) == 1
            else { return nil }
            return (source, MIDIEntityGetDestination(entity, 0))
        }
    }
    nonisolated static func copyPacketBytes(_ list: UnsafePointer<MIDIPacketList>) -> ([UInt8], Bool) {
        // Copy packet storage before CoreMIDI reclaims it. Bound each callback batch.
        var bytes: [UInt8] = []
        var overflow = false
        do {
            let first = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!)
                .assumingMemoryBound(to: MIDIPacket.self)
            var packet = first
            for _ in 0..<list.pointee.numPackets {
                let count = Int(packet.pointee.length)
                if bytes.count + count > 8192 {
                    overflow = true
                    break
                }
                let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!)
                bytes.append(
                    contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
        }
        return (bytes, overflow)
    }
    private func receive(_ bytes: [UInt8], source: MIDIEndpointRef, generation: UUID, overflow: Bool) {
        guard var connection = connections[source], connection.generation == generation else { return }
        if overflow {
            connection.decoder = MIDIStreamDecoder()
            connection.identity = nil
            connections[source] = connection
            changed()
            return
        }
        if Date().timeIntervalSince(connection.lastBytes) > 0.5 { connection.decoder = MIDIStreamDecoder() }
        connection.lastBytes = Date()
        let messages = connection.decoder.consume(bytes)
        connections[source] = connection
        for message in messages {
            if case .systemExclusive(let data) = message, let identity = QEQHardwareIdentity(message: data) {
                let different = connections[source]?.identity != identity
                connections[source]?.identity = identity
                connections[source]?.lastSeen = Date()
                if different {
                    connections[source]?.lastFeedback = nil
                    connections[source]?.capabilities = nil
                    connections[source]?.restored = false
                    connections[source]?.lastLEDs = []
                    changed()
                }
            } else if let identity = connections[source]?.identity {
                if case .systemExclusive(let data) = message {
                    if let caps = HardwareCapabilities(message: data, identity: identity) {
                        if connections[source]?.capabilities != caps {
                            connections[source]?.capabilities = caps
                            changed()
                        }
                        // Send a heartbeat first: configuration requires a live host session.
                        sendFeedback(force: true)
                        if connections[source]?.restored == false {
                            connections[source]?.restored = true
                            for pair in caps.pairs {
                                if let data = UserDefaults.standard.data(
                                    forKey: calibrationKey(identity.serial, pair.id)),
                                    let setting = try? JSONDecoder().decode(HardwareCalibration.self, from: data),
                                    setting.valid
                                {
                                    calibrate(source: source, pair: pair.id, setting: setting) { [weak self] reading in
                                        if reading == nil { self?.connections[source]?.restored = false }
                                    }
                                }
                            }
                        }
                    } else if let reading = HardwareCalibrationReading(message: data, identity: identity),
                        let item = pending[reading.token], item.source == source, item.boot == identity.boot,
                        item.pair == reading.pair
                    {
                        pending.removeValue(forKey: reading.token)
                        if let setting = item.setting {
                            guard setting == reading.calibration else {
                                item.completion(nil)
                                continue
                            }
                            if let encoded = try? JSONEncoder().encode(setting) {
                                UserDefaults.standard.set(
                                    encoded, forKey: calibrationKey(identity.serial, reading.pair))
                            }
                            onCalibrationChanged?(source, reading.pair)
                        }
                        item.completion(reading)
                    } else if data.count == 18, identity.matches(data, kind: 9), data[15] == 4 {
                        let token = HardwareCalibrationReading.token(data)
                        if let item = mediaPending[token], item.0 == source {
                            mediaPending.removeValue(forKey: token)
                            item.1(data[16] == 0)
                        }
                    }
                } else if !pending.values.contains(where: { $0.source == source && $0.setting != nil }) {
                    onMessage?(source, message)
                }
            }
        }
        if !messages.isEmpty { requestFeedback() }
    }
    private func tick() {
        var expired = false
        for source in Array(connections.keys) {
            if connections[source]?.identity != nil,
                Date().timeIntervalSince(connections[source]!.lastSeen) > 3
            {
                connections[source]?.identity = nil
                connections[source]?.capabilities = nil
                connections[source]?.decoder = MIDIStreamDecoder()
                expired = true
            }
        }
        if expired { changed() }
        sendFeedback(force: true)
    }
    private func sendFeedback(force: Bool) {
        for device in devices {
            if let bytes = feedback?(device), let destination = connections[device.source]?.destination {
                if force || connections[device.source]?.lastFeedback != bytes {
                    if send(bytes, to: destination) { connections[device.source]?.lastFeedback = bytes }
                }
            }
            if let destination = connections[device.source]?.destination, let frames = ledFeedback?(device) {
                if force || connections[device.source]?.lastLEDs != frames {
                    var success = true
                    for bytes in frames { if !send(bytes, to: destination) { success = false } }
                    if success { connections[device.source]?.lastLEDs = frames }
                }
            }
        }
    }
    private func send(_ bytes: [UInt8], to destination: MIDIEndpointRef) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        var list = MIDIPacketList()
        return bytes.withUnsafeBufferPointer { buffer in
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIPacketListInit(pointer)
                // The fixed 64-byte protocol bound fits in this stack packet list.
                MIDIPacketListAdd(
                    pointer, MemoryLayout<MIDIPacketList>.size, packet, 0,
                    bytes.count, buffer.baseAddress!)
                let result = MIDISend(output, destination, pointer)
                if result != noErr { status = "MIDI feedback failed (\(result))" }
                return result == noErr
            }
        }
    }
}
