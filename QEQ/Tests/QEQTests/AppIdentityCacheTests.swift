import Foundation
import Testing

@testable import QEQAppSupport

@Test func cachedIdentityExpiresAndCannotFollowReusedProcesses() {
    let cache = AppIdentityCache()
    var resolves = 0
    func read(object: UInt32 = 10, pid: Int32 = 20, bundle: String = "helper", now: Double = 0) -> String {
        cache.identity(object: object, pid: pid, bundleID: bundle, now: now) {
            resolves += 1
            return AppIdentity(id: "app.\(resolves)", name: "App", url: URL(fileURLWithPath: "/App.app"))
        }.id
    }
    #expect(read() == "app.1")
    #expect(read(now: 29) == "app.1")
    #expect(read(now: 30) == "app.2")
    #expect(read(pid: 21, now: 31) == "app.3")
    #expect(read(pid: 21, bundle: "new.helper", now: 32) == "app.4")
    cache.retain(processes: [])
    #expect(read(pid: 21, bundle: "new.helper", now: 33) == "app.5")
}

@Test func unresolvedHelperIsRetriedWithoutWaitingForCacheExpiry() {
    let cache = AppIdentityCache()
    let missing = cache.identity(object: 10, pid: 20, bundleID: "helper", now: 0) {
        AppIdentity(id: "helper", name: "Helper", url: nil)
    }
    let found = cache.identity(object: 10, pid: 20, bundleID: "helper", now: 1) {
        AppIdentity(id: "parent", name: "Parent", url: URL(fileURLWithPath: "/Parent.app"))
    }
    #expect(missing.id == "helper")
    #expect(found.id == "parent")
}
