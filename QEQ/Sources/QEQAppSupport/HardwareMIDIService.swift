import CoreMIDI
import Foundation
import QEQCore

/// CoreMIDI owns delivery threads; parsing and all client callbacks run on MainActor.
@MainActor
public final class HardwareMIDIService {
    public struct Device: Equatable, Sendable {
        public let source: MIDIEndpointRef
        public let identity: QEQHardwareIdentity
    }
    private struct Connection {
        var port: MIDIPortRef
        var destination: MIDIEndpointRef
        var generation: UUID
        var decoder = MIDIStreamDecoder()
        var identity: QEQHardwareIdentity?
        var lastSeen = Date.distantPast
        var lastBytes = Date.distantPast
        var lastFeedback: [UInt8]?
    }
    public var onDevicesChanged: (([Device]) -> Void)?
    public var onMessage: ((MIDIEndpointRef, MIDIMessage) -> Void)?
    public var feedback: ((Device) -> [UInt8])?
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
            connection.identity.map { Device(source: source, identity: $0) }
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
                    changed()
                }
            } else if connections[source]?.identity != nil {
                onMessage?(source, message)
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
