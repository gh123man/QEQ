import Foundation

public struct HardwareSlotBinding: Equatable, Identifiable, Sendable {
    public let serial: String
    public let number: Int
    public let appID: String?
    public let appName: String?
    public let appPath: String?
    public var id: String { "\(serial).\(number)" }
    public init(serial: String, number: Int, appID: String?, appName: String?, appPath: String? = nil) {
        self.serial = serial
        self.number = number
        self.appID = appID
        self.appName = appName
        self.appPath = appPath
    }
}

/// Slot ownership is durable device configuration, independent of running apps.
@MainActor
public final class HardwareSlotAssignments {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ serial: String, _ number: Int) -> String { "hardwareTarget.\(serial).\(number)" }
    public func slots(serial: String, count: Int) -> [HardwareSlotBinding] {
        (0..<min(4, max(0, count))).map { index in
            let number = index + 1
            let target =
                defaults.string(forKey: key(serial, number))
                ?? (index == 0 ? defaults.string(forKey: "hardwareTarget.\(serial)") : nil)
            return HardwareSlotBinding(
                serial: serial, number: number, appID: target,
                appName: defaults.string(forKey: key(serial, number) + ".name"),
                appPath: defaults.string(forKey: key(serial, number) + ".path"))
        }
    }
    public func assign(appID: String, appName: String, serial: String, number: Int, appPath: String? = nil) {
        guard !appID.isEmpty, (1...4).contains(number) else { return }
        // Migrate the original single-slider key before removing it, even when
        // the user is assigning a different app to a different slot.
        if defaults.string(forKey: key(serial, 1)) == nil,
            let legacy = defaults.string(forKey: "hardwareTarget.\(serial)")
        {
            defaults.set(legacy, forKey: key(serial, 1))
        }
        for slot in slots(serial: serial, count: 4) where slot.number != number && slot.appID == appID {
            defaults.removeObject(forKey: key(serial, slot.number))
            defaults.removeObject(forKey: key(serial, slot.number) + ".name")
            defaults.removeObject(forKey: key(serial, slot.number) + ".path")
        }
        defaults.set(appID, forKey: key(serial, number))
        defaults.set(appName, forKey: key(serial, number) + ".name")
        defaults.set(appPath, forKey: key(serial, number) + ".path")
        defaults.removeObject(forKey: "hardwareTarget.\(serial)")
    }
    public func allAssignedSlots() -> [HardwareSlotBinding] {
        let serials = Set(
            defaults.dictionaryRepresentation().keys.compactMap { key -> String? in
                guard key.hasPrefix("hardwareTarget.") else { return nil }
                return String(key.dropFirst("hardwareTarget.".count).split(separator: ".").first ?? "")
            }.filter { !$0.isEmpty })
        return serials.sorted().flatMap { slots(serial: $0, count: 4) }.filter { $0.appID != nil }
    }
    public func unassign(appID: String) {
        for slot in allAssignedSlots() where slot.appID == appID {
            defaults.removeObject(forKey: key(slot.serial, slot.number))
            defaults.removeObject(forKey: key(slot.serial, slot.number) + ".name")
            defaults.removeObject(forKey: key(slot.serial, slot.number) + ".path")
            if slot.number == 1 { defaults.removeObject(forKey: "hardwareTarget.\(slot.serial)") }
        }
    }
    public func rememberMetadata(_ app: AudioApplication, for slot: HardwareSlotBinding) {
        guard slot.appID == app.id else { return }
        if slot.appName != app.name { defaults.set(app.name, forKey: key(slot.serial, slot.number) + ".name") }
        if let path = app.path, slot.appPath != path {
            defaults.set(path, forKey: key(slot.serial, slot.number) + ".path")
        }
    }
    public static func retainedApplications(from bindings: [HardwareSlotBinding]) -> [AudioApplication] {
        var apps: [String: AudioApplication] = [:]
        for slot in bindings {
            guard let id = slot.appID, apps[id] == nil else { continue }
            apps[id] = AudioApplication(id: id, name: slot.appName ?? id, path: slot.appPath)
        }
        return apps.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
