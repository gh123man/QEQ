import CoreGraphics
import Foundation

/// Wire pixels use logical, post-orientation coordinates and RGB565 LE.
public struct HardwareDisplayCapabilities: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var format: Int
    public var orientation: Int
    public var shape: Int
    public init(width: Int = 240, height: Int = 240, format: Int = 1, orientation: Int = 0, shape: Int = 1) {
        self.width = width
        self.height = height
        self.format = format
        self.orientation = orientation
        self.shape = shape
    }
    public var supported: Bool {
        (1...1024).contains(width) && (1...1024).contains(height) && format == 1 && (0...3).contains(orientation)
            && (0...1).contains(shape) && ((width + 31) / 32) * ((height + 31) / 32) <= 1024
    }
}

public struct HardwareDisplayScene: Equatable, Sendable {
    public var label: String
    public var percent: Int
    public var systemPercent: Int?
    public var available: Bool
    public var muted: Bool
    public var enabled: Bool
    public var pickup: Bool
    public var red: Double
    public var green: Double
    public var blue: Double
    public var roundScreen: HardwareRoundScreen?
    public var roundShowsSystemVolume = false
    public var roundSpectrumTraces: [HardwareSpectrumTrace] = []
    public var roundVolumePosition = 1.0
    public var roundSliderHint: Int?
    public var reduceMotion = false
    public init(
        label: String, percent: Int, systemPercent: Int?, available: Bool = true,
        muted: Bool = false, enabled: Bool = true, pickup: Bool = false,
        red: Double = 0.3, green: Double = 0.65, blue: Double = 1
    ) {
        self.label = label
        self.percent = percent
        self.systemPercent = systemPercent
        self.available = available
        self.muted = muted
        self.enabled = enabled
        self.pickup = pickup
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct HardwareSpectrumTrace: Equatable, Sendable {
    public var bins: [UInt8]
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(bins: [UInt8], red: Double, green: Double, blue: Double) {
        self.bins = bins
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum HardwareRoundScreen: Equatable, Sendable {
    public enum Page: Equatable, Sendable { case home, menu, music, appActions, slots, app, slider }
    case home([UInt8])
    public struct Item: Equatable, Sendable {
        public var label: String
        public var iconKey: String
        public var detail: String
        public var enabled: Bool
        public init(_ label: String, iconKey: String, detail: String = "", enabled: Bool = true) {
            self.label = label
            self.iconKey = iconKey
            self.detail = detail
            self.enabled = enabled
        }
    }
    case menu(items: [Item], selected: Int)
    case appActions(appID: String, title: String, items: [Item], selected: Int)
    case slots(appID: String, title: String, items: [Item], selected: Int)
    case music(player: String, selected: Int, status: String)
    case app(slider: Bool)

    public var page: Page {
        switch self {
        case .home: .home
        case .menu: .menu
        case .appActions: .appActions
        case .slots: .slots
        case .music: .music
        case .app(let slider): slider ? .slider : .app
        }
    }
    var carousel: (items: [Item], selected: Int, title: String, key: String)? {
        switch self {
        case .menu(let items, let selected): return (items, selected, "", "menu")
        case .appActions(let id, let title, let items, let selected): return (items, selected, title, "actions." + id)
        case .slots(let id, let title, let items, let selected): return (items, selected, title, "slots." + id)
        default: return nil
        }
    }

}

extension HardwareRoundScreen.Page {
    var navigationDepth: Int {
        switch self {
        case .home: 0
        case .menu: 1
        case .music, .appActions: 2
        case .slots, .app: 3
        case .slider: 4
        }
    }
}

/// Immutable image snapshots cross queues; each renderer remains confined to its worker.
public struct HardwareDisplayContent: @unchecked Sendable, Equatable {
    public var scene: HardwareDisplayScene
    public var icon: CGImage?
    public var iconKey: String
    public var menuIcons: [String: CGImage]
    public init(scene: HardwareDisplayScene, icon: CGImage?, iconKey: String, menuIcons: [String: CGImage] = [:]) {
        self.scene = scene
        self.icon = icon
        self.iconKey = iconKey
        self.menuIcons = menuIcons
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.scene == rhs.scene && lhs.iconKey == rhs.iconKey }
}
