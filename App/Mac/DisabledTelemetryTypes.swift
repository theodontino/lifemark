// Local inert types keep the upstream call sites source-compatible.
// Crash reporting is intentionally absent from this independently distributed app.
import Foundation
enum BreadcrumbLevel { case debug, info, warning, error }
final class Breadcrumb {
    var message: String?
    var data: [String: Any]?
    var type: String?
    init(level: BreadcrumbLevel, category: String) {}
}
final class Scope { func setContext(value: [String: Any], key: String) {} }
enum LocalSpanStatus { case ok, internalError }
final class Span {
    func setData(value: Any, key: String) {}
    func finish(status: LocalSpanStatus) {}
}
enum SentrySDK {
    static func capture(message: String) {}
    static func flush(timeout: TimeInterval) {}
}

