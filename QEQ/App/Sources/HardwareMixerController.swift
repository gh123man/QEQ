import AppKit
import QEQAppSupport
import QEQCore

@MainActor
final class HardwareMixerController {
    private struct Session {
        enum Page {
            case home, menu, music
            case app(String)
        }
        var identity: QEQHardwareIdentity
        var target: String?
        var controls = HardwareControlState()
        var position: Double?
        var maximum: Double?
        var available = false
        var page = Page.home
        var menuIndex = 1
        var musicIndex = 1
        var musicPlayer = MusicPlayer.music
        var round = false
        var sliderMotion = HardwareSliderMotion()
        var overlay: Task<Void, Never>?
        var systemVolumeOverlay: Task<Void, Never>?
        var idleReturn: Task<Void, Never>?
        var systemPercent: Int?

        var showsSpectrum: Bool {
            if case .home = page { return round && overlay == nil }
            return false
        }
    }
    private enum MusicPlayer: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var label: String { self == .music ? "Apple Music" : "Spotify" }
        var eventClass: UInt32 { self == .music ? 0x686F_6F6B : 0x7370_6679 }  // hook / spfy
        var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }
    private enum MusicCommand: UInt32 {
        case previous = 0x5072_6576  // Prev
        case playPause = 0x506C_5073  // PlPs
        case next = 0x4E65_7874  // Next
    }
    private weak var model: MixerModel?
    private let midi = HardwareMIDIService()
    private let systemVolume = SystemOutputVolume()
    private let display = HardwareDisplayService()
    private var sessions: [UInt32: Session] = [:]
    private var spectrum: [UInt8] = []
    private var spectrumTraces: [HardwareSpectrumTrace] = []
    private var musicStatus = "Turn to select · press"
    private var musicCommandRunning = false
    var diagnostics: String {
        midi.status + (systemVolume.error.map { "; \($0)" } ?? "")
            + (display.status.isEmpty ? "" : "; \(display.status)")
    }
    init(model: MixerModel) { self.model = model }
    func start() {
        display.onNeedsScene = { [weak self] in self?.displayChanged() }
        display.start()
        midi.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            let sources = Set(devices.map(\.source))
            for source in Array(self.sessions.keys) where !sources.contains(source) {
                self.sessions[source]?.overlay?.cancel()
                self.sessions[source]?.systemVolumeOverlay?.cancel()
                self.sessions[source]?.idleReturn?.cancel()
                self.sessions.removeValue(forKey: source)
            }
            for device in devices where self.sessions[device.source]?.identity != device.identity {
                self.sessions[device.source]?.overlay?.cancel()
                self.sessions[device.source]?.systemVolumeOverlay?.cancel()
                self.sessions[device.source]?.idleReturn?.cancel()
                self.sessions[device.source] = Session(
                    identity: device.identity,
                    target: UserDefaults.standard.string(forKey: "hardwareTarget.\(device.identity.serial)"))
            }
            self.model?.hardwareStatus =
                devices.isEmpty && self.midi.status == "No QEQ controller connected" ? "" : self.midi.status
            self.displayChanged()
        }
        midi.onMessage = { [weak self] source, message in self?.receive(source, message: message) }
        midi.feedback = { [weak self] device in self?.feedback(device) ?? [] }
        midi.start()
    }
    func stop() {
        for source in Array(sessions.keys) {
            sessions[source]?.overlay?.cancel()
            sessions[source]?.overlay = nil
            sessions[source]?.systemVolumeOverlay?.cancel()
            sessions[source]?.systemVolumeOverlay = nil
            sessions[source]?.idleReturn?.cancel()
            sessions[source]?.idleReturn = nil
        }
        display.stop()
        midi.stop()
    }
    func reconnect() {
        stop()
        start()
    }
    func refreshFeedback() { midi.requestFeedback() }

    private func displayChanged() {
        for source in Array(sessions.keys) {
            guard let serial = sessions[source]?.identity.serial else { continue }
            if display.hasRoundDisplay(serial: serial) { sessions[source]?.round = true }
        }
        refreshSpectrumDemand()
        refreshFeedback()
    }

    private func refreshSpectrumDemand() {
        model?.setHardwareSpectrumVisible(
            sessions.values.contains {
                $0.showsSpectrum && display.hasRoundDisplay(serial: $0.identity.serial)
            })
    }

    func audioDidUpdate(_ reading: AudioTelemetry) {
        func bins(_ spectrum: [Float]) -> [UInt8] {
            SpectrumPlotValues(spectrum: spectrum).values.map { UInt8(($0 * 255).rounded()) }
        }
        let next = bins(reading.spectrum)
        let traces = (model?.snapshot.apps.filter { $0.playing }.prefix(6) ?? []).compactMap {
            app -> HardwareSpectrumTrace? in
            guard let color = model?.appAccentColor(for: app).usingColorSpace(.sRGB) else { return nil }
            return HardwareSpectrumTrace(
                bins: bins(reading.apps[app.id]?.spectrum ?? []),
                red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
        guard spectrum != next || spectrumTraces != traces else { return }
        spectrum = next
        spectrumTraces = traces
        for session in sessions.values where session.showsSpectrum { publishRound(session) }
    }
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
        var interacted = false
        if case .control(15, 16, let value) = message {
            let previous = session.sliderMotion.lastAccepted
            guard session.sliderMotion.accept(value) else { return }
            if session.round, previous != nil {
                showSlider(source, session: &session)
                interacted = true
            }
        }
        let action = session.controls.receive(message, targetPosition: session.position ?? 1)
        if action != nil { interacted = true }
        switch action {
        case .systemVolume(let delta):
            if session.round {
                turn(delta, source: source, session: &session)
            } else {
                systemVolume.adjust(steps: delta)
            }
        case .toggleGlobalBypass:
            if session.round {
                press(session: &session)
            } else {
                model.toggle(!model.enabled)
            }
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
        if session.round, interacted { resetIdleReturn(source, session: &session) }
        sessions[source] = session
        if session.round {
            refreshSpectrumDemand()
            publishRound(session)
        }
    }

    private func resetIdleReturn(_ source: UInt32, session: inout Session) {
        session.idleReturn?.cancel()
        session.idleReturn = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, let self, var session = self.sessions[source] else { return }
            session.overlay?.cancel()
            session.overlay = nil
            session.systemVolumeOverlay?.cancel()
            session.systemVolumeOverlay = nil
            session.idleReturn = nil
            session.page = .home
            session.menuIndex = 1
            self.sessions[source] = session
            self.refreshSpectrumDemand()
            self.publishRound(session)
        }
    }

    private func showSlider(_ source: UInt32, session: inout Session) {
        session.overlay?.cancel()
        session.overlay = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, let self, var session = self.sessions[source] else { return }
            session.overlay = nil
            if case .home = session.page { session.menuIndex = 1 }
            session.page = .menu
            self.sessions[source] = session
            self.refreshSpectrumDemand()
            self.publishRound(session)
        }
    }

    private func showSystemVolume(_ source: UInt32, session: inout Session) {
        session.systemVolumeOverlay?.cancel()
        session.systemVolumeOverlay = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, let self, var session = self.sessions[source] else { return }
            session.systemVolumeOverlay = nil
            self.sessions[source] = session
            self.publishRound(session)
        }
    }

    private func menuApps() -> [AudioApplication] {
        model?.snapshot.apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        } ?? []
    }

    private func turn(_ delta: Int, source: UInt32, session: inout Session) {
        session.overlay?.cancel()
        session.overlay = nil
        switch session.page {
        case .home:
            showSystemVolume(source, session: &session)
            systemVolume.adjust(steps: delta)
            session.systemPercent = systemVolume.value().map { Int(($0 * 100).rounded()) }
            refreshFeedback()
        case .menu:
            session.menuIndex = min(menuApps().count + 1, max(0, session.menuIndex + delta))
        case .music:
            session.musicIndex = ((session.musicIndex + delta) % 4 + 4) % 4
        case .app:
            break
        }
    }

    private func press(session: inout Session) {
        if let overlay = session.overlay {
            overlay.cancel()
            session.overlay = nil
            return
        }
        switch session.page {
        case .home:
            session.menuIndex = 1
            session.page = .menu
        case .menu:
            let apps = menuApps()
            session.menuIndex = min(session.menuIndex, apps.count + 1)
            if session.menuIndex == 0 {
                session.page = .home
            } else if session.menuIndex == 1 {
                session.musicIndex = 1
                session.musicPlayer = musicPlayer()
                musicStatus = "Turn to select · press"
                session.page = .music
            } else {
                session.page = .app(apps[session.menuIndex - 2].id)
            }
        case .music:
            if session.musicIndex == 3 {
                session.page = .menu
            } else {
                sendMusicCommand(
                    [MusicCommand.previous, .playPause, .next][session.musicIndex], to: session.musicPlayer)
            }
        case .app:
            session.page = .menu
        }
    }

    private func musicPlayer() -> MusicPlayer {
        let running = MusicPlayer.allCases.filter(\.running)
        return running.first { player in
            model?.snapshot.apps.contains {
                $0.playing && $0.id.caseInsensitiveCompare(player.rawValue) == .orderedSame
            }
                == true
        } ?? running.first ?? .music
    }

    private func sendMusicCommand(_ command: MusicCommand, to player: MusicPlayer) {
        guard !musicCommandRunning else { return }
        guard player.running else {
            musicStatus = "Open \(player.label) on Mac"
            return
        }
        musicCommandRunning = true
        musicStatus = "Sending…"
        let bundleID = player.rawValue
        let eventClass = player.eventClass
        let eventID = command.rawValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let event = NSAppleEventDescriptor(
                eventClass: eventClass, eventID: eventID,
                targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                returnID: -1, transactionID: 0)
            let status: String
            do {
                let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 10)
                status =
                    (reply.paramDescriptor(forKeyword: 0x6572_726E)?.int32Value ?? 0) == 0
                    ? "Turn to select · press" : "Music command failed"
            } catch {
                status = (error as NSError).code == -1743 ? "Allow QEQ in Automation" : "Music command failed"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.musicCommandRunning = false
                self.musicStatus = status
                self.refreshFeedback()
            }
        }
    }

    private static func navigationIcon(_ name: String) -> NSImage? {
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Playback")?
                .withSymbolConfiguration(.init(paletteColors: [.white]))
        else { return nil }
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.42, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 10, dy: 10), xRadius: 26, yRadius: 26).fill()
            symbol.draw(in: rect.insetBy(dx: 32, dy: 32))
            return true
        }
    }

    private func publishRound(_ session: Session) {
        guard let model else { return }
        var target = session.target
        let screen: HardwareRoundScreen
        var menuIcons: [String: NSImage] = [:]
        if session.overlay != nil {
            screen = .app(slider: true)
        } else {
            switch session.page {
            case .home:
                screen = .home(spectrum)
            case .menu:
                let apps = menuApps()
                let items =
                    [
                        HardwareRoundScreen.Item("Home", iconKey: "home"),
                        HardwareRoundScreen.Item("Playback", iconKey: "playback"),
                    ]
                    + apps.map { HardwareRoundScreen.Item($0.name, iconKey: $0.id) }
                for app in apps { menuIcons[app.id] = model.icon(for: app) }
                menuIcons["playback"] = Self.navigationIcon("playpause.fill")
                if let symbol = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Home") {
                    let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                        NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.7, alpha: 1).setFill()
                        NSBezierPath(roundedRect: rect.insetBy(dx: 10, dy: 10), xRadius: 26, yRadius: 26).fill()
                        symbol.draw(in: rect.insetBy(dx: 37, dy: 37))
                        return true
                    }
                    menuIcons["home"] = image
                }
                screen = .menu(items: items, selected: min(session.menuIndex, items.count - 1))
            case .music:
                screen = .music(player: session.musicPlayer.label, selected: session.musicIndex, status: musicStatus)
            case .app(let id):
                target = id
                screen = .app(slider: false)
            }
        }
        let app = model.snapshot.apps.first { $0.id == target }
        let settings = model.value(target ?? "")
        let isApp = screen.page == .app || screen.page == .slider
        let color =
            isApp
            ? app.flatMap { model.appAccentColor(for: $0).usingColorSpace(.sRGB) }
            : NSColor.controlAccentColor.usingColorSpace(.sRGB)
        var scene = HardwareDisplayScene(
            label: isApp ? app?.name ?? "App unavailable" : "",
            percent: isApp ? Int((settings.volume * 100).rounded()) : 0,
            systemPercent: screen.page == .home ? session.systemPercent : nil,
            available: isApp && app != nil, muted: isApp && settings.muted, enabled: !isApp || model.enabled,
            pickup: screen.page == .slider && !session.controls.pickedUp, red: Double(color?.redComponent ?? 0),
            green: Double(color?.greenComponent ?? 0), blue: Double(color?.blueComponent ?? 0))
        scene.roundScreen = screen
        scene.roundShowsSystemVolume = screen.page == .home && session.systemVolumeOverlay != nil
        scene.roundSpectrumTraces = screen.page == .home ? spectrumTraces : []
        scene.roundVolumePosition =
            isApp ? VolumeSliderScale(maximum: settings.maximumVolume).position(for: settings.volume) : 0
        scene.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        display.publish(
            scene, serial: session.identity.serial, icon: isApp ? app.flatMap { model.icon(for: $0) } : nil,
            iconKey: isApp ? app?.id ?? "unavailable" : "round", menuIcons: menuIcons)
    }
    private func feedback(_ device: HardwareMIDIService.Device) -> [UInt8] {
        guard let model, var session = synchronized(device.source) else { return [] }
        let outputVolume = systemVolume.value()
        let percent = outputVolume.map { Int(($0 * 100).rounded()) }
        if case .home = session.page, session.systemPercent != nil, percent != session.systemPercent {
            showSystemVolume(device.source, session: &session)
        }
        session.systemPercent = percent
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
        if session.round {
            publishRound(session)
        } else {
            display.publish(
                HardwareDisplayScene(
                    label: app?.name ?? "App unavailable",
                    percent: Int((settings.volume * 100).rounded()),
                    systemPercent: outputVolume.map { Int(($0 * 100).rounded()) },
                    available: session.available, muted: settings.muted, enabled: model.enabled,
                    pickup: !session.controls.pickedUp, red: Double(color?.redComponent ?? 0),
                    green: Double(color?.greenComponent ?? 0), blue: Double(color?.blueComponent ?? 0)),
                serial: device.identity.serial, icon: app.flatMap { model.icon(for: $0) },
                iconKey: app?.id ?? "unavailable"
            )
        }
        return device.identity.feedback(
            position: session.position ?? 1,
            percent: Int((settings.volume * 100).rounded()), available: session.available,
            muted: settings.muted, enabled: model.enabled,
            pickup: !session.controls.pickedUp, label: app?.name ?? "App unavailable",
            accent: accent, systemVolume: outputVolume)
    }
}
