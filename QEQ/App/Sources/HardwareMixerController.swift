import AppKit
import QEQAppSupport
import QEQCore

@MainActor
final class HardwareMixerController {
    private struct Session {
        var identity: QEQHardwareIdentity
        var target: String?
        var controls = HardwareControlState()
        var position: Double?
        var maximum: Double?
        var available = false
    }
    private weak var model: MixerModel?
    private let midi = HardwareMIDIService()
    private let systemVolume = SystemOutputVolume()
    private let display = HardwareDisplayService()
    private var sessions: [UInt32: Session] = [:]
    var diagnostics: String {
        midi.status + (systemVolume.error.map { "; \($0)" } ?? "")
            + (display.status.isEmpty ? "" : "; \(display.status)")
    }
    init(model: MixerModel) { self.model = model }
    func start() {
        display.onNeedsScene = { [weak self] in self?.refreshFeedback() }
        display.start()
        midi.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            let sources = Set(devices.map(\.source))
            self.sessions = self.sessions.filter { sources.contains($0.key) }
            for device in devices where self.sessions[device.source]?.identity != device.identity {
                self.sessions[device.source] = Session(
                    identity: device.identity,
                    target: UserDefaults.standard.string(forKey: "hardwareTarget.\(device.identity.serial)"))
            }
            self.model?.hardwareStatus =
                devices.isEmpty && self.midi.status == "No QEQ controller connected" ? "" : self.midi.status
        }
        midi.onMessage = { [weak self] source, message in self?.receive(source, message: message) }
        midi.feedback = { [weak self] device in self?.feedback(device) ?? [] }
        midi.start()
    }
    func stop() {
        display.stop()
        midi.stop()
    }
    func reconnect() {
        stop()
        start()
    }
    func refreshFeedback() { midi.requestFeedback() }
    func selectApp(_ id: String) {
        guard model?.snapshot.apps.contains(where: { $0.id == id }) == true else { return }
        for source in Array(sessions.keys) {
            sessions[source]?.target = id
            sessions[source]?.controls.rearm()
            sessions[source]?.position = nil
            if let session = sessions[source] {
                UserDefaults.standard.set(id, forKey: "hardwareTarget.\(session.identity.serial)")
            }
        }
        refreshFeedback()
    }
    private func synchronized(_ source: UInt32) -> Session? {
        guard let model, var session = sessions[source] else { return nil }
        if session.target == nil, let first = model.snapshot.apps.sorted(by: { $0.id < $1.id }).first {
            session.target = first.id
            UserDefaults.standard.set(first.id, forKey: "hardwareTarget.\(session.identity.serial)")
        }
        let available = model.snapshot.apps.contains { $0.id == session.target }
        let settings = model.value(session.target ?? "")
        let position = VolumeSliderScale(maximum: settings.maximumVolume).position(for: settings.volume)
        if session.position != position || session.maximum != settings.maximumVolume || session.available != available {
            session.controls.rearm()
        }
        session.position = position
        session.maximum = settings.maximumVolume
        session.available = available
        return session
    }
    private func receive(_ source: UInt32, message: MIDIMessage) {
        guard let model, var session = synchronized(source) else { return }
        let action = session.controls.receive(message, targetPosition: session.position ?? 1)
        switch action {
        case .systemVolume(let delta):
            systemVolume.adjust(steps: delta)
        case .toggleGlobalBypass:
            model.toggle(!model.enabled)
        case .volume(let position):
            if session.available, let target = session.target {
                let scale = VolumeSliderScale(maximum: model.value(target).maximumVolume)
                model.edit(target) { $0.volume = scale.gain(at: position) }
                session.position = scale.position(for: model.value(target).volume)
            }
        case .toggleMute:
            if session.available, let target = session.target { model.edit(target) { $0.muted.toggle() } }
        case nil: break
        }
        sessions[source] = session
    }
    private func feedback(_ device: HardwareMIDIService.Device) -> [UInt8] {
        guard let model, let session = synchronized(device.source) else { return [] }
        sessions[device.source] = session
        let app = model.snapshot.apps.first { $0.id == session.target }
        let settings = model.value(session.target ?? "")
        let color = app.flatMap { model.appAccentColor(for: $0).usingColorSpace(.sRGB) }
        func channel(_ value: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, value.isFinite ? value : 0)) * 127).rounded())
        }
        let accent = (
            channel(color?.redComponent ?? 0), channel(color?.greenComponent ?? 0),
            channel(color?.blueComponent ?? 0)
        )
        let outputVolume = systemVolume.value()
        display.publish(
            HardwareDisplayScene(
                label: app?.name ?? "App unavailable",
                percent: Int((settings.volume * 100).rounded()),
                systemPercent: outputVolume.map { Int(($0 * 100).rounded()) },
                available: session.available, muted: settings.muted, enabled: model.enabled,
                pickup: !session.controls.pickedUp, red: Double(color?.redComponent ?? 0),
                green: Double(color?.greenComponent ?? 0), blue: Double(color?.blueComponent ?? 0)),
            serial: device.identity.serial, icon: app.flatMap { model.icon(for: $0) }, iconKey: app?.id ?? "unavailable"
        )
        return device.identity.feedback(
            position: session.position ?? 1,
            percent: Int((settings.volume * 100).rounded()), available: session.available,
            muted: settings.muted, enabled: model.enabled,
            pickup: !session.controls.pickedUp, label: app?.name ?? "App unavailable",
            accent: accent, systemVolume: outputVolume)
    }
}
