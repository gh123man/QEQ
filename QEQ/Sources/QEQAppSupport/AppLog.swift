import Foundation
import os

public enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    case debug, info, warning, error, off
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

/// Serial, bounded file logging. Never called by the real-time DSP callback.
public final class AppLog: @unchecked Sendable {
    public static let levelKey = "logging.level"
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QEQ", isDirectory: true)
    public static let shared = AppLog(
        directory: directory,
        level: LogLevel(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .warning)
    private let directory: URL
    private let queue = DispatchQueue(label: "local.AppMixer.logs", qos: .utility)
    private let threshold: OSAllocatedUnfairLock<LogLevel>
    private let maxBytes: Int
    private let formatter = ISO8601DateFormatter()
    private var current: URL { directory.appendingPathComponent("qeq.log") }
    private var previous: URL { directory.appendingPathComponent("qeq.previous.log") }
    public init(directory: URL, level: LogLevel = .warning, maxBytes: Int = 1_000_000) {
        self.directory = directory
        self.threshold = OSAllocatedUnfairLock(initialState: level)
        self.maxBytes = max(256, maxBytes)
    }
    public var level: LogLevel {
        get { threshold.withLock { $0 } }
        set { threshold.withLock { $0 = newValue } }
    }
    public func write(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level != .off, threshold.withLock({ $0 != .off && level.rank >= $0.rank }) else { return }
        let text = message().replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        // A malformed system error cannot make an unbounded log entry.
        let limited = String(text.prefix(min(2000, (maxBytes - 80) / 4)))
        let date = Date()
        queue.async { [self] in
            do {
                try prepareDirectory()
                let line = "\(formatter.string(from: date)) [\(level.rawValue.uppercased())] \(limited)\n"
                let data = Data(line.utf8)
                let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size + data.count > maxBytes {
                    if FileManager.default.fileExists(atPath: previous.path) {
                        try FileManager.default.removeItem(at: previous)
                    }
                    if FileManager.default.fileExists(atPath: current.path) {
                        try FileManager.default.moveItem(at: current, to: previous)
                    }
                }
                if !FileManager.default.fileExists(atPath: current.path) {
                    FileManager.default.createFile(
                        atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging must never interrupt audio or UI work.
            }
        }
    }
    public func collect(diagnostics: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var result = Data(("QEQ diagnostic log\n\n" + diagnostics + "\n\nRecent logs\n").utf8)
                    for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        result.append(try handle.read(upToCount: maxBytes) ?? Data())
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
