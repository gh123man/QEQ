import AppKit
import Foundation
@preconcurrency import QEQHardware
import os

protocol DisplayBulkPort: AnyObject {
    func write(_ data: Data) throws
    func read(timeout: TimeInterval) throws -> Data
    func diagnosticStatus() -> String
    func close()
}
extension DisplayBulkPort {
    func diagnosticStatus() -> String { "Diagnostics unavailable" }
}
private final class NativeDisplayPort: DisplayBulkPort {
    let endpoint: QEQUSBEndpoint
    init(_ device: QEQUSBDevice) throws { endpoint = try QEQUSBEndpoint(device: device) }
    func write(_ data: Data) throws { try endpoint.write(data) }
    func read(timeout: TimeInterval) throws -> Data { try endpoint.read(withTimeout: timeout) }
    func diagnosticStatus() -> String { endpoint.diagnosticStatus() }
    func close() { endpoint.close() }
}
protocol DisplayPixelRenderer: AnyObject {
    var animating: Bool { get }
    var frameInterval: TimeInterval { get }
    func pixels(_ content: HardwareDisplayContent) throws -> Data
}
extension DisplayPixelRenderer {
    var animating: Bool { false }
    var frameInterval: TimeInterval { 0 }
}
private final class NativeDisplayRenderer: DisplayPixelRenderer {
    private let capabilities: HardwareDisplayCapabilities
    private var metal: MetalHardwareDisplayRenderer?
    private let round: RoundDisplayRenderer
    private var usesRoundScreen = false
    var animating: Bool { usesRoundScreen && round.animating }
    var frameInterval: TimeInterval { usesRoundScreen ? 1.0 / 30 : 0 }
    init(_ capabilities: HardwareDisplayCapabilities) throws {
        self.capabilities = capabilities
        round = try RoundDisplayRenderer(capabilities)
    }
    func pixels(_ content: HardwareDisplayContent) throws -> Data {
        usesRoundScreen = content.scene.roundScreen != nil
        if usesRoundScreen { return round.render(content) }
        let renderer = try metal ?? MetalHardwareDisplayRenderer(capabilities: capabilities)
        metal = renderer
        return try renderer.render(content.scene, icon: content.icon, iconKey: content.iconKey)
    }
}

/// A synchronous session owned only by one background queue. ACK loss always discards this session.
final class DisplayUSBSession {
    private(set) var activity = "opening"
    let port: any DisplayBulkPort
    let nonce: UInt32
    private var decoder = DisplayWire.Decoder()
    private var received: [DisplayWire.Message] = []
    private(set) var planner: DisplayFramePlanner?
    init(port: any DisplayBulkPort, nonce: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.port = port
        self.nonce = nonce
    }
    func negotiate() throws -> HardwareDisplayCapabilities {
        activity = "writing HELLO"
        try port.write(DisplayWire.Message(kind: .hello, session: nonce).encoded())
        activity = "reading capabilities"
        for _ in 0..<8 {
            let reply = try readMessage()
            if reply.session != nonce { continue }  // A prior host's expiry reply may still be buffered.
            guard reply.kind == .capabilities, reply.flags == 0, reply.frame == 0, reply.base == 0 else {
                throw DisplayWire.Failure.sequence
            }
            let caps = try DisplayWire.Capabilities(reply.payload).display
            planner = DisplayFramePlanner(capabilities: caps, session: nonce)
            return caps
        }
        throw DisplayWire.Failure.sequence
    }
    @discardableResult func send(_ pixels: Data) throws -> Bool {
        activity = "preparing frame"
        guard var planner else { throw DisplayWire.Failure.sequence }
        guard let frame = try planner.prepare(pixels) else { return false }
        // Keep pending state until ACK validation succeeds; failures invalidate the whole session.
        self.planner = planner
        activity = "writing frame \(frame.frame) (\(frame.tiles) tiles, \(frame.wire.count) bytes)"
        try port.write(frame.wire)
        activity = "reading ACK for frame \(frame.frame)"
        try planner.accept(readMessage())
        self.planner = planner
        return true
    }
    func heartbeat() throws {
        activity = "writing heartbeat"
        guard let planner else { throw DisplayWire.Failure.sequence }
        try port.write(
            DisplayWire.Message(kind: .ping, session: nonce, frame: planner.acknowledged, base: planner.acknowledged)
                .encoded())
        activity = "reading heartbeat reply"
        try planner.validatePong(readMessage())
    }
    private func readMessage() throws -> DisplayWire.Message {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while received.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayWire.Failure.timeout }
            let bytes = try port.read(timeout: 0.75)
            received.append(contentsOf: try decoder.feed(bytes))
            guard received.count <= 8 else { throw DisplayWire.Failure.malformed }
        }
        return received.removeFirst()
    }
    func close() { port.close() }
}

/// All render/codec/USB work is queue-confined. Callers replace one locked mailbox,
/// even while a frame blocks for its ACK; they cannot enqueue a backlog of scenes.
final class DisplayConnection: @unchecked Sendable {
    private let logger = Logger(subsystem: "local.AppMixer", category: "HardwareDisplay")
    struct Mailbox {
        var content: HardwareDisplayContent?
        var version: UInt64 = 0
        var scheduled = false
        var active = true
    }
    private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())
    private let queue: DispatchQueue
    private let makePort: @Sendable () throws -> any DisplayBulkPort
    private let makeRenderer: @Sendable (HardwareDisplayCapabilities) throws -> any DisplayPixelRenderer
    private let onStatus: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer!
    private var session: DisplayUSBSession?
    private var renderer: (any DisplayPixelRenderer)?
    private var renderedVersion: UInt64?
    private var failures = 0
    private var retryAt: TimeInterval = 0
    private var heartbeatAt: TimeInterval = 0
    private var renderAt: TimeInterval = 0
    private var status = ""
    init(
        label: String, makePort: @escaping @Sendable () throws -> any DisplayBulkPort,
        makeRenderer: @escaping @Sendable (HardwareDisplayCapabilities) throws -> any DisplayPixelRenderer,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        queue = DispatchQueue(label: "QEQ.display.\(label)", qos: .userInitiated)
        self.makePort = makePort
        self.makeRenderer = makeRenderer
        self.onStatus = onStatus
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.schedule() }
        timer.schedule(deadline: .distantFuture)
        timer.activate()
    }
    func start() { schedule() }
    func update(_ content: HardwareDisplayContent) {
        let changed = mailbox.withLock { state in
            guard state.active, state.content != content else { return false }
            state.content = content
            state.version &+= 1
            return true
        }
        if changed { schedule() }
    }
    func stop() {
        mailbox.withLock {
            $0.active = false
            $0.content = nil
        }
        queue.async { [self] in
            timer.cancel()
            session?.close()
            session = nil
            renderer = nil
        }
    }
    private var active: Bool { mailbox.withLock { $0.active } }
    private func schedule() {
        let needed = mailbox.withLock { state in
            guard state.active, !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if needed { queue.async { [self] in pump() } }
    }
    private func setStatus(_ value: String) {
        guard value != status else { return }
        status = value
        onStatus(value)
    }
    private func pump() {
        guard active else {
            mailbox.withLock { $0.scheduled = false }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= retryAt {
            do {
                if session == nil {
                    setStatus("Connecting display")
                    let next = DisplayUSBSession(port: try makePort())
                    session = next  // Close even when negotiation fails.
                    let caps = try next.negotiate()
                    logger.notice("Display connected: \(caps.width)x\(caps.height)")
                    guard active else { throw DisplayWire.Failure.stopped }
                    renderer = try makeRenderer(caps)
                    renderedVersion = nil
                    heartbeatAt = 0
                    renderAt = 0
                }
                let snapshot = mailbox.withLock { ($0.version, $0.content) }
                if let content = snapshot.1, let renderer, now >= renderAt,
                    renderedVersion != snapshot.0 || renderer.animating
                {
                    let started = ProcessInfo.processInfo.systemUptime
                    let pixels = try autoreleasepool { try renderer.pixels(content) }
                    guard active else { throw DisplayWire.Failure.stopped }
                    if try session?.send(pixels) == true {
                        heartbeatAt = ProcessInfo.processInfo.systemUptime + 0.5
                    }
                    renderedVersion = snapshot.0
                    renderAt = started + renderer.frameInterval
                }
                if ProcessInfo.processInfo.systemUptime >= heartbeatAt {
                    try session?.heartbeat()
                    heartbeatAt = ProcessInfo.processInfo.systemUptime + 0.5
                }
                failures = 0
                setStatus("Display streaming")
            } catch {
                let failure = error as NSError
                logger.error(
                    "Display failure during \(self.session?.activity ?? "opening", privacy: .public): \(String(reflecting: error), privacy: .public), domain=\(failure.domain, privacy: .public), code=\(failure.code)"
                )
                if let session {
                    logger.error("Display firmware: \(session.port.diagnosticStatus(), privacy: .public)")
                }
                session?.close()
                session = nil
                renderedVersion = nil
                failures = min(5, failures + 1)
                retryAt = ProcessInfo.processInfo.systemUptime + min(8, pow(2, Double(failures - 1)) * 0.5)
                setStatus("Display reconnecting: \(error.localizedDescription)")
            }
        }
        let next = mailbox.withLock { state -> (Bool, Bool) in
            state.scheduled = false
            return (state.active, state.content != nil && renderedVersion != state.version)
        }
        guard next.0 else { return }
        let pendingFrame = next.1 || renderer?.animating == true
        let deadline = session == nil ? retryAt : pendingFrame ? min(heartbeatAt, renderAt) : heartbeatAt
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(2))
        // update() either schedules immediately or replaced the mailbox during this work;
        // the one-shot timer covers both cases without a periodic render loop.
    }
}

private struct USBDisplayDevice: @unchecked Sendable {
    let device: QEQUSBDevice  // Immutable retained IORegistry descriptor, not an open USB user client.
}

@MainActor
public final class HardwareDisplayService {
    private let discovery = QEQUSBDiscovery()
    private var generation = UUID()
    private var started = false
    private var connections: [UInt64: (serial: String, round: Bool, connection: DisplayConnection)] = [:]
    private var statuses: [UInt64: String] = [:]
    private var icons: [String: (key: String, image: CGImage?)] = [:]
    private var menuIconCache: [String: CGImage] = [:]
    public var onNeedsScene: (() -> Void)?
    private var diagnosticMIDIOnly: Bool { ProcessInfo.processInfo.arguments.contains("--hardware-midi-only") }
    public var status: String {
        diagnosticMIDIOnly
            ? "Display disabled for MIDI-only diagnosis"
            : statuses.sorted { $0.key < $1.key }.map(\.value).joined(separator: "; ")
    }
    public init() {}
    public func start() {
        guard !diagnosticMIDIOnly else { return }
        guard !started else { return }
        started = true
        generation = UUID()
        let token = generation
        discovery.start { @Sendable [weak self] devices in
            let values = devices.map { USBDisplayDevice(device: $0) }
            Task { @MainActor in
                guard let self, self.started, self.generation == token else { return }
                self.apply(values, token: token)
            }
        }
    }
    public func stop() {
        guard started else { return }
        started = false
        generation = UUID()
        discovery.stop()
        for item in connections.values { item.connection.stop() }
        connections.removeAll()
        statuses.removeAll()
        icons.removeAll()
        menuIconCache.removeAll()
    }
    private func apply(_ devices: [USBDisplayDevice], token: UUID) {
        let ids = Set(devices.map { $0.device.registryID })
        for id in connections.keys.filter({ !ids.contains($0) }) {
            connections.removeValue(forKey: id)?.connection.stop()
            statuses[id] = nil
        }
        for descriptor in devices where connections[descriptor.device.registryID] == nil {
            let id = descriptor.device.registryID
            let serial = Self.midiSerial(descriptor.device.serial)
            guard let serial else { continue }
            let worker = DisplayConnection(
                label: String(id), makePort: { try NativeDisplayPort(descriptor.device) },
                makeRenderer: { try NativeDisplayRenderer($0) },
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.connections[id] != nil else { return }
                        self.statuses[id] = status
                    }
                })
            let round = ["QEQ Test Board Display", "QEQ Test Board V2 Display"].contains(descriptor.device.productName)
            connections[id] = (serial, round, worker)
            worker.start()
        }
        let serials = Set(connections.values.map(\.serial))
        icons = icons.filter { serials.contains($0.key) }
        onNeedsScene?()
    }
    nonisolated static func midiSerial(_ usbSerial: String) -> String? {
        let serial =
            usbSerial.hasSuffix("-D1") || usbSerial.hasSuffix("-D2") ? String(usbSerial.dropLast(3)) : usbSerial
        guard serial.count == 12, serial.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            return nil
        }
        return serial
    }
    public func publish(
        _ scene: HardwareDisplayScene, serial: String, icon: NSImage?, iconKey: String,
        menuIcons: [String: NSImage] = [:]
    ) {
        let workers = connections.values.filter { $0.serial == serial }
        guard !workers.isEmpty else { return }
        if icons[serial]?.key != iconKey {
            var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
            icons[serial] = (iconKey, icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        }
        for (key, image) in menuIcons where menuIconCache[key] == nil {
            var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
            menuIconCache[key] = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        // Bound cached assets to the currently published app list.
        if !menuIcons.isEmpty { menuIconCache = menuIconCache.filter { menuIcons[$0.key] != nil } }
        let content = HardwareDisplayContent(
            scene: scene, icon: icons[serial]?.image, iconKey: iconKey,
            menuIcons: menuIconCache)
        for item in workers { item.connection.update(content) }
    }

    public func hasRoundDisplay(serial: String) -> Bool {
        connections.values.contains { $0.serial == serial && $0.round }
    }
}
