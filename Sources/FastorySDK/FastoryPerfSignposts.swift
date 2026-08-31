import Foundation
import os.signpost

enum FastoryPerfSignposts {
    private static let log = OSLog(subsystem: "io.fastory.sdk", category: "Perf")

    private static let bootstrapWaitName: StaticString = "hubBootstrapWait"
    private static let hubLoadName: StaticString = "hubLoad"

    private static var bootstrapWait: OSSignpostID?
    private static var hubLoad: OSSignpostID?

    static func beginBootstrapWait() {
        let id = OSSignpostID(log: log)
        bootstrapWait = id
        os_signpost(.begin, log: log, name: bootstrapWaitName, signpostID: id)
    }

    static func endBootstrapWait() {
        guard let id = bootstrapWait else { return }
        bootstrapWait = nil
        os_signpost(.end, log: log, name: bootstrapWaitName, signpostID: id)
    }

    static func beginHubLoad() {
        let id = OSSignpostID(log: log)
        hubLoad = id
        os_signpost(.begin, log: log, name: hubLoadName, signpostID: id)
    }

    static func endHubLoad() {
        guard let id = hubLoad else { return }
        hubLoad = nil
        os_signpost(.end, log: log, name: hubLoadName, signpostID: id)
    }
}
