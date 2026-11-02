import Foundation

/// QEQ publishes stable versions and numbered RCs. Reject other or malformed tags.
public struct ReleaseVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let rc: Int?
    public init?(_ text: String) {
        var value = text
        if value.hasPrefix("v") { value.removeFirst() }
        let pieces = value.components(separatedBy: "-rc.")
        guard pieces.count <= 2 else { return nil }
        let core = pieces[0].components(separatedBy: ".")
        func number(_ text: String) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                text == "0" || !text.hasPrefix("0")
            else { return nil }
            return Int(text)
        }
        guard core.count == 3, let major = number(core[0]), let minor = number(core[1]),
            let patch = number(core[2])
        else { return nil }
        var rc: Int?
        if pieces.count == 2 {
            guard let candidate = number(pieces[1]), candidate > 0 else { return nil }
            rc = candidate
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.rc = rc
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.rc, rhs.rc) {
        case (.none, _): return false
        case (.some, .none): return true
        case (.some(let left), .some(let right)): return left < right
        }
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public var releaseURL: URL { ReleaseChecker.releasesURL.appendingPathComponent("tag/v\(version)") }
    public var feedURL: URL { ReleaseChecker.releasesURL.appendingPathComponent("download/v\(version)/appcast.xml") }
    public init(version: String) { self.version = version }
}

public struct ReleaseChecker: Sendable {
    public static let releasesURL = URL(string: "https://github.com/gh123man/QEQ/releases")!
    public static let interval: TimeInterval = 24 * 60 * 60
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let state: String
            let size: Int
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    public func check(currentVersion: String, includeRC: Bool) async throws -> AvailableUpdate? {
        guard ReleaseVersion(currentVersion) != nil else { throw UpdateError.invalidVersion }
        let endpoint = includeRC ? "releases?per_page=100" : "releases/latest"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/gh123man/QEQ/\(endpoint)")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("QEQ/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.unavailable }
        // Public repositories with only RCs have no /latest stable release yet.
        if response.statusCode == 404 && !includeRC { return nil }
        guard response.statusCode == 200 else { throw UpdateError.unavailable }
        let releases =
            includeRC
            ? try JSONDecoder().decode([Release].self, from: data)
            : [try JSONDecoder().decode(Release.self, from: data)]
        return Self.select(releases, currentVersion: currentVersion, includeRC: includeRC)
    }
    static func select(_ releases: [Release], currentVersion: String, includeRC: Bool) -> AvailableUpdate? {
        guard let current = ReleaseVersion(currentVersion) else { return nil }
        let candidates = releases.compactMap { release -> (ReleaseVersion, String)? in
            guard !release.draft, let version = ReleaseVersion(release.tagName), version > current,
                (!release.prerelease && version.rc == nil) || (includeRC && version.rc != nil)
            else { return nil }
            let bare = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            let assets = Set(release.assets.filter { $0.state == "uploaded" && $0.size > 0 }.map(\.name))
            // Old RCs without an appcast cannot be installed by Sparkle.
            guard assets.contains("appcast.xml"), assets.contains("QEQ-\(bare)-macOS.zip") else { return nil }
            return (version, bare)
        }
        return candidates.max(by: { $0.0 < $1.0 }).map { AvailableUpdate(version: $0.1) }
    }
    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        // Also recover from a clock adjustment into the past.
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
    }
}

public enum UpdateError: LocalizedError {
    case invalidVersion, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidVersion: "This build has no release version."
        case .unavailable: "Couldn’t check GitHub for updates. Try again later."
        }
    }
}
