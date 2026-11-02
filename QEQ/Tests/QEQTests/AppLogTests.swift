import Foundation
import Testing

@testable import QEQAppSupport

@Test func logsFilterLazilyRedactHomeAndClear() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AppLog(directory: directory, level: .warning)
    var evaluated = false
    func expensiveMessage() -> String {
        evaluated = true
        return "debug-only"
    }
    log.write(.debug, expensiveMessage())
    #expect(!evaluated)
    log.write(.error, "Problem in \(NSHomeDirectory())/example\nnext line")
    let text = String(decoding: try await log.collect(diagnostics: "Test snapshot"), as: UTF8.self)
    #expect(text.contains("Test snapshot"))
    #expect(text.contains("~/example next line"))
    #expect(!text.contains(NSHomeDirectory()))
    #expect(!text.contains("debug-only"))
    log.level = .off
    log.write(.error, "disabled")
    try await log.clear()
    let cleared = String(decoding: try await log.collect(diagnostics: "After clear"), as: UTF8.self)
    #expect(!cleared.contains("Problem"))
    #expect(!cleared.contains("disabled"))
}

@Test func logRetentionIsBoundedAndKeepsRecentEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AppLog(directory: directory, level: .debug, maxBytes: 512)
    for index in 0..<60 { log.write(.debug, "event-\(index): " + String(repeating: "x", count: 200)) }
    let data = try await log.collect(diagnostics: "Bounded test")
    #expect(data.count < 1200)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("event-59"))
    #expect(!text.contains("event-0:"))
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
    #expect(files.count == 2)
    for file in files { #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 512) }
}
