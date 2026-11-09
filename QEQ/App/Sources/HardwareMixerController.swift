import AppKit
import QEQAppSupport
import QEQCore
import SwiftUI

@MainActor
final class HardwareMixerController {
    private struct Session {
        enum Page {
            case home, menu, music
            case appActions(String)
            case appVolume(String)
            case appSlots(String)
        }
        var identity: QEQHardwareIdentity
        struct Pair {
            var target: String?
            var controls = HardwareControlState()
            var sliderMotion = HardwareSliderMotion()
            var position: Double?
            var maximum: Double?
            var available = false
        }
        var pairs = Array(repeating: Pair(), count: 4)
        var activePair = 0
        var capabilities: HardwareCapabilities?
        var navigation = HardwareControlState()
        var target: String? {
            get { pairs[activePair].target }
            set { pairs[activePair].target = newValue }
        }
        var controls: HardwareControlState {
            get { pairs[activePair].controls }
            set { pairs[activePair].controls = newValue }
        }
        var sliderMotion: HardwareSliderMotion {
            get { pairs[activePair].sliderMotion }
            set { pairs[activePair].sliderMotion = newValue }
        }
        var position: Double? {
            get { pairs[activePair].position }
            set { pairs[activePair].position = newValue }
        }
        var maximum: Double? {
            get { pairs[activePair].maximum }
            set { pairs[activePair].maximum = newValue }
        }
        var available: Bool {
            get { pairs[activePair].available }
            set { pairs[activePair].available = newValue }
        }
        var page = Page.home
        var menuIndex = 1
        var actionIndex = HardwareAppAction.boost.rawValue
        var slotIndex = 0
        var musicIndex = 1
        var musicStatus = ""
        var round = false
        var overlay: Task<Void, Never>?
        var systemVolumeOverlay: Task<Void, Never>?
        var idleReturn: Task<Void, Never>?
        var systemPercent: Int?
        var sliderHint = false

        var showsSpectrum: Bool {
            if case .home = page { return round && overlay == nil }
            return false
        }
    }
    private weak var model: MixerModel?
    private let midi = HardwareMIDIService()
    private let assignments = HardwareSlotAssignments()
    private let systemVolume = SystemOutputVolume()
    private let display = HardwareDisplayService()
    private var sessions: [UInt32: Session] = [:]
    private var spectrum: [UInt8] = []
    private var spectrumTraces: [HardwareSpectrumTrace] = []
    private var calibrationWindow: NSWindow?
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
                var session = Session(identity: device.identity)
                for slot in self.assignments.slots(serial: device.identity.serial, count: 4) {
                    session.pairs[slot.number - 1].target = slot.appID
                }
                self.sessions[device.source] = session
            }
            for device in devices { self.sessions[device.source]?.capabilities = device.capabilities }
            self.model?.hardwareStatus =
                devices.isEmpty && self.midi.status == "No QEQ controller connected" ? "" : self.midi.status
            self.publishSlots()
            self.displayChanged()
        }
        midi.onMessage = { [weak self] source, message in self?.receive(source, message: message) }
        midi.feedback = { [weak self] device in self?.feedback(device) ?? [] }
        midi.ledFeedback = { [weak self] device in self?.ledFeedback(device) ?? [] }
        midi.onCalibrationChanged = { [weak self] source, pair in
            guard let self, self.sessions[source] != nil else { return }
            self.sessions[source]?.pairs[Int(pair) - 1].controls = HardwareControlState()
            self.sessions[source]?.pairs[Int(pair) - 1].sliderMotion = HardwareSliderMotion()
        }
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
    func refreshFeedback() {
        publishSlots()
        midi.requestFeedback()
    }
    private func publishSlots() {
        guard let model else { return }
        let slots = sessions.values.sorted { $0.identity.serial < $1.identity.serial }.flatMap { session in
            assignments.slots(serial: session.identity.serial, count: session.capabilities?.pairs.count ?? 1).map {
                slot in
                let app = model.snapshot.apps.first(where: { $0.id == slot.appID })
                if let app { assignments.rememberMetadata(app, for: slot) }
                return HardwareSlotBinding(
                    serial: slot.serial, number: slot.number, appID: slot.appID,
                    appName: app?.name ?? slot.appName, appPath: app?.path ?? slot.appPath)
            }
        }
        if model.hardwareSlots != slots { model.hardwareSlots = slots }
        let saved = assignments.allAssignedSlots()
        if model.hardwareBindings != saved { model.hardwareBindings = saved }
    }

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
    func selectApp(_ id: String, name: String, slot: HardwareSlotBinding) {
        guard let source = sessions.first(where: { $0.value.identity.serial == slot.serial })?.key,
            var session = sessions[source], slot.number >= 1,
            slot.number <= (session.capabilities?.pairs.count ?? 1)
        else { return }
        assignApp(id, name: name, number: slot.number, session: &session)
        sessions[source] = session
        refreshFeedback()
    }
    private func assignApp(_ id: String, name: String, number: Int, session: inout Session) {
        assignments.assign(
            appID: id, appName: name, serial: session.identity.serial, number: number,
            appPath: model?.snapshot.apps.first(where: { $0.id == id })?.path)
        for binding in assignments.slots(serial: session.identity.serial, count: 4) {
            let index = binding.number - 1
            guard session.pairs[index].target != binding.appID else { continue }
            session.pairs[index].target = binding.appID
            session.pairs[index].controls.rearm(sliderPosition: session.pairs[index].sliderMotion.lastAccepted)
            session.pairs[index].position = nil
        }
    }
    func unassignApp(_ id: String) {
        assignments.unassign(appID: id)
        for source in Array(sessions.keys) {
            guard var session = sessions[source] else { continue }
            for index in session.pairs.indices where session.pairs[index].target == id {
                session.pairs[index].target = nil
                session.pairs[index].controls.rearm(sliderPosition: session.pairs[index].sliderMotion.lastAccepted)
                session.pairs[index].position = nil
            }
            sessions[source] = session
        }
        refreshFeedback()
    }
    private func synchronized(_ source: UInt32) -> Session? {
        guard let model, var session = sessions[source] else { return nil }
        for index in 0..<(session.capabilities?.pairs.count ?? 1) {
            var pair = session.pairs[index]
            let available = model.snapshot.apps.contains { $0.id == pair.target }
            let settings = model.value(pair.target ?? "")
            let position = VolumeSliderScale(maximum: settings.maximumVolume).position(for: settings.volume)
            if pair.position != position || pair.maximum != settings.maximumVolume || pair.available != available {
                pair.controls.rearm(sliderPosition: pair.sliderMotion.lastAccepted)
            }
            pair.position = position
            pair.maximum = settings.maximumVolume
            pair.available = available
            session.pairs[index] = pair
        }
        if case .appVolume(let id) = session.page, mappedSlot(id) != nil {
            session.page = .appActions(id)
            session.actionIndex = HardwareAppAction.volume.rawValue
        }
        return session
    }
    private func receive(_ source: UInt32, message: MIDIMessage) {
        guard let model, var session = synchronized(source) else { return }
        if session.capabilities == nil {
            guard session.identity.model == 1,
                session.identity.controls.flatMap({ [$0.id, $0.kind, $0.controller] })
                    == QEQHardwareIdentity.testBoardControls
            else { return }
        }
        guard case .control(15, let controller, let value) = message,
            let descriptor = session.identity.controls.first(where: { $0.controller == controller })
        else { return }
        let previouslyActive = session.activePair
        var normalized = message
        var pairIndex: Int?
        if let pairs = session.capabilities?.pairs {
            pairIndex = pairs.firstIndex { $0.slider == descriptor.id || $0.button == descriptor.id }
            if let index = pairIndex {
                normalized = .control(channel: 15, number: descriptor.kind == 0 ? 16 : 19, value: value)
                session.activePair = index
            }
        } else if descriptor.id == 1 || descriptor.id == 4 {
            pairIndex = 0
            session.activePair = 0
        }
        if pairIndex == nil {
            guard
                descriptor.id == (session.capabilities?.encoder ?? 2)
                    || descriptor.id == (session.capabilities?.encoderButton ?? 3)
            else { return }
            normalized = .control(channel: 15, number: descriptor.kind == 1 ? 17 : 18, value: value)
        }
        var interacted = false
        if case .control(15, 16, let value) = normalized {
            let previous = session.sliderMotion.lastAccepted
            guard session.sliderMotion.accept(value) else { return }
            if session.round, previous != nil {
                showSlider(source, session: &session)
                interacted = true
            }
        }
        let action =
            pairIndex == nil
            ? session.navigation.receive(normalized, targetPosition: 1)
            : session.controls.receive(normalized, targetPosition: session.position ?? 1)
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
                press(source: source, session: &session)
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
        if !interacted { session.activePair = previouslyActive }
        if session.round, interacted { resetIdleReturn(source, session: &session) }
        sessions[source] = session
        if action == .toggleGlobalBypass { refreshFeedback() }
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
            session.sliderHint = false
            self.sessions[source] = session
            self.refreshSpectrumDemand()
            self.publishRound(session)
        }
    }

    private func showSlider(_ source: UInt32, session: inout Session) {
        session.sliderHint = false
        session.overlay?.cancel()
        session.overlay = nil
        // The selected app already owns this view; update its volume in place.
        if case .appVolume(let id) = session.page, id == session.target { return }
        session.overlay = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, let self, var session = self.sessions[source] else { return }
            // The overlay leaves the underlying page and selection intact.
            // Dismissing it reveals exactly where the slider interrupted the UI.
            session.overlay = nil
            session.sliderHint = false
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
        if session.overlay != nil {
            showSlider(source, session: &session)
            session.sliderHint = true
            return
        }
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
        case .appActions:
            session.actionIndex = min(HardwareAppAction.allCases.count - 1, max(0, session.actionIndex + delta))
        case .appSlots:
            session.slotIndex = min((session.capabilities?.pairs.count ?? 1) + 1, max(0, session.slotIndex + delta))
        case .appVolume(let id):
            guard let model else { return }
            let settings = model.value(id)
            guard
                let volume = HardwareAppAction.adjustedVolume(
                    settings.volume, maximum: settings.maximumVolume,
                    steps: delta, mapped: mappedSlot(id) != nil)
            else {
                session.sliderHint = true
                return
            }
            model.edit(id) { $0.volume = volume }
        }
    }

    private func press(source: UInt32, session: inout Session) {
        session.sliderHint = false
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
                session.musicStatus = ""
                session.page = .music
            } else {
                session.actionIndex = HardwareAppAction.boost.rawValue
                session.page = .appActions(apps[session.menuIndex - 2].id)
            }
        case .music:
            if session.musicIndex == 3 {
                session.page = .menu
            } else {
                session.musicStatus = ""
                let identity = session.identity
                midi.sendMedia([HardwareMediaCommand.previous, .playPause, .next][session.musicIndex], source: source) {
                    [weak self] accepted in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessions[source]?.identity == identity else { return }
                        self.sessions[source]?.musicStatus = accepted ? "" : "Media key unavailable"
                        self.refreshFeedback()
                    }
                }
            }
        case .appActions(let id):
            guard let model, let action = HardwareAppAction(rawValue: session.actionIndex) else { return }
            guard action.canActivate(mapped: mappedSlot(id) != nil) else {
                session.sliderHint = true
                return
            }
            switch action {
            case .boost: model.edit(id) { $0.boostEnabled.toggle() }
            case .mute:
                model.edit(id) {
                    $0.muted.toggle()
                    if $0.muted { $0.enabled = true }
                }
            case .volume: session.page = .appVolume(id)
            case .slot:
                session.slotIndex = session.pairs.firstIndex(where: { $0.target == id }) ?? 0
                session.page = .appSlots(id)
            case .back: session.page = .menu
            }
        case .appVolume(let id):
            session.page = .appActions(id)
            session.actionIndex = HardwareAppAction.volume.rawValue
        case .appSlots(let id):
            let count = session.capabilities?.pairs.count ?? 1
            if session.slotIndex < count {
                let name = model?.snapshot.apps.first(where: { $0.id == id })?.name ?? id
                assignApp(id, name: name, number: session.slotIndex + 1, session: &session)
            } else if session.slotIndex == count {
                unassignApp(id)
                // unassignApp updates all devices; keep the current in-flight session in sync.
                if let updated = sessions[source] { session.pairs = updated.pairs }
            }
            session.page = .appActions(id)
            session.actionIndex = HardwareAppAction.slot.rawValue
        }
    }

    private func mappedSlot(_ id: String) -> HardwareSlotBinding? {
        model?.hardwareBindings.first { $0.appID == id }
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
                screen = .music(player: "System audio", selected: session.musicIndex, status: session.musicStatus)
            case .appActions(let id):
                target = id
                let settings = model.value(id)
                let slot = mappedSlot(id)
                let symbols = [
                    settings.boostEnabled ? "bolt.fill" : "bolt",
                    settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    "speaker.wave.2.fill", "slider.vertical.3", "arrow.uturn.backward",
                ]
                let names = ["Boost", "Mute", "Volume", "Slot", "Back"]
                let details = [
                    settings.boostEnabled ? "On" : "Off", settings.muted ? "On" : "Off",
                    slot.map { "Use slider \($0.number)" } ?? "\(Int((settings.volume * 100).rounded()))%",
                    slot.map { "Slot \($0.number)" } ?? "Unassigned", "",
                ]
                let items = HardwareAppAction.allCases.map { action in
                    let index = action.rawValue
                    let key = "action.\(index).\(symbols[index])"
                    menuIcons[key] = Self.navigationIcon(symbols[index])
                    return HardwareRoundScreen.Item(
                        names[index], iconKey: key, detail: details[index],
                        enabled: action.canActivate(mapped: slot != nil))
                }
                screen = .appActions(
                    appID: id, title: model.snapshot.apps.first(where: { $0.id == id })?.name ?? "App", items: items,
                    selected: session.actionIndex)
            case .appSlots(let id):
                target = id
                let slots = assignments.slots(
                    serial: session.identity.serial, count: session.capabilities?.pairs.count ?? 1)
                var items = slots.map { slot in
                    let key = "slot.\(slot.number)"
                    menuIcons[key] = Self.navigationIcon("\(slot.number).circle")
                    return HardwareRoundScreen.Item(
                        "Slot \(slot.number)", iconKey: key,
                        detail: slot.appID == id ? "Assigned" : slot.appName ?? slot.appID ?? "Available")
                }
                menuIcons["slot.clear"] = Self.navigationIcon("xmark.circle")
                menuIcons["slot.back"] = Self.navigationIcon("arrow.uturn.backward")
                items += [
                    .init("Unassign", iconKey: "slot.clear", enabled: mappedSlot(id) != nil),
                    .init("Back", iconKey: "slot.back"),
                ]
                screen = .slots(
                    appID: id, title: model.snapshot.apps.first(where: { $0.id == id })?.name ?? "App", items: items,
                    selected: min(session.slotIndex, items.count - 1))
            case .appVolume(let id):
                target = id
                screen = .app(slider: false)
            }
        }
        let app = model.snapshot.apps.first { $0.id == target }
        let settings = model.value(target ?? "")
        let isApp = [.app, .slider, .appActions, .slots].contains(screen.page)
        let color =
            isApp
            ? app.flatMap { model.appAccentColor(for: $0).usingColorSpace(.sRGB) }
            : NSColor.controlAccentColor.usingColorSpace(.sRGB)
        var scene = HardwareDisplayScene(
            label: isApp
                ? app?.name ?? (target == nil ? "Assign slider \(session.activePair + 1)" : "App unavailable") : "",
            percent: isApp ? Int((settings.volume * 100).rounded()) : 0,
            systemPercent: screen.page == .home ? session.systemPercent : nil,
            available: isApp && app != nil, muted: isApp && settings.muted, enabled: !isApp || model.enabled,
            pickup: screen.page == .slider && !session.controls.pickedUp, red: Double(color?.redComponent ?? 0),
            green: Double(color?.greenComponent ?? 0), blue: Double(color?.blueComponent ?? 0))
        scene.roundScreen = screen
        scene.roundSliderHint =
            isApp && session.sliderHint
            ? session.pairs.firstIndex(where: { $0.target == target && target != nil }).map { $0 + 1 } : nil
        scene.roundShowsSystemVolume = screen.page == .home && session.systemVolumeOverlay != nil
        scene.roundSpectrumTraces = screen.page == .home ? spectrumTraces : []
        scene.roundVolumePosition =
            isApp ? VolumeSliderScale(maximum: settings.maximumVolume).position(for: settings.volume) : 0
        scene.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        display.publish(
            scene, serial: session.identity.serial, icon: isApp ? app.flatMap { model.icon(for: $0) } : nil,
            iconKey: isApp ? app?.id ?? "unavailable" : "round", menuIcons: menuIcons)
    }
    private func ledFeedback(_ device: HardwareMIDIService.Device) -> [[UInt8]] {
        guard let model, let session = sessions[device.source], let caps = device.capabilities, caps.hasLEDs else {
            return []
        }
        return caps.pairs.compactMap { pair in
            let target = session.pairs[Int(pair.id) - 1].target
            let app = model.snapshot.apps.first { $0.id == target }
            let color = app.flatMap { model.appAccentColor(for: $0).usingColorSpace(.sRGB) }
            func channel(_ value: CGFloat?) -> UInt8 { UInt8((min(1, max(0, value ?? 0)) * 127).rounded()) }
            return device.identity.led(
                id: pair.led, red: channel(color?.redComponent), green: channel(color?.greenComponent),
                blue: channel(color?.blueComponent))
        }
    }
    func showCalibration(serial: String, pair: Int) {
        guard
            let device = midi.devices.first(where: {
                $0.identity.serial == serial && $0.capabilities?.hasCalibration == true
                    && ($0.capabilities?.pairs.count ?? 0) > pair
            })
        else { return }
        calibrationWindow?.close()
        let view = HardwareCalibrationView(service: midi, source: device.source, pair: UInt8(pair + 1))
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Calibrate slider \(pair + 1) · \(device.identity.serial)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        calibrationWindow = window
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
