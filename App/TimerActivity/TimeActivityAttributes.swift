import ActivityKit
import Foundation

/// Shared by the application and extension; contains no database or account dependencies.
struct TimeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var category: String
        var isRunning: Bool
    }
    var timerID: String
    var start: Date
}
