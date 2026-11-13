#if os(macOS)
import Foundation
import GRDB
import LifeCore
import LifeStore

@MainActor
enum DayflowLifeIntegration {
    private static let deviceID: String = {
        let key = "lifeRecord.screenSourceDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let value = "mac-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    private static var isSyncing = false
    private static var needsAnotherSnapshot = false

    /// Returns a user-visible error, or nil after a complete local snapshot committed.
    /// No images, frame paths, accessibility text, or network calls cross this boundary.
    static func syncDayflowSummaries() async -> String? {
        if isSyncing {
            needsAnotherSnapshot = true
            return nil
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsAnotherSnapshot = false
            if let error = await importSnapshot() { return error }
        } while needsAnotherSnapshot
        return nil
    }

    private static func importSnapshot() async -> String? {
        do {
            let store = try LifeIntegrationStore.result.get()
            let sourceDevice = deviceID
            let windowStart = Date(timeIntervalSince1970: 946684800)
            let windowEnd = Date()
            let summaries: [ScreenSummary] = try await Task.detached(priority: .utility) {
                try StorageManager.shared.timedRead("LifeRecord.screenSummaries") { db in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT id, start_ts, end_ts, title, category, summary
                        FROM timeline_cards
                        WHERE is_deleted = 0 AND batch_id IS NOT NULL AND category != 'System'
                          AND start_ts >= ? AND end_ts <= ?
                        ORDER BY start_ts, id
                        """, arguments: [Int(windowStart.timeIntervalSince1970), Int(windowEnd.timeIntervalSince1970)])
                    return try rows.map { row in
                        guard let id: Int64 = row["id"], let start: Int = row["start_ts"],
                              let end: Int = row["end_ts"], end > start,
                              let title: String = row["title"], let category: String = row["category"] else {
                            throw NSError(domain: "LifeRecord.DayflowImport", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "屏幕摘要数据不完整，本次未覆盖已有记录。"])
                        }
                        return ScreenSummary(id: String(id), title: title, category: category,
                                             start: Date(timeIntervalSince1970: TimeInterval(start)),
                                             end: Date(timeIntervalSince1970: TimeInterval(end)),
                                             summary: row["summary"] ?? "", deviceID: sourceDevice)
                    }
                }
            }.value
            try store.importScreenSummaries(summaries, windowStart: windowStart,
                                            windowEnd: windowEnd, deviceID: sourceDevice)
            return nil
        } catch {
            return "屏幕摘要导入失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
func syncDayflowSummaries() async -> String? {
    await DayflowLifeIntegration.syncDayflowSummaries()
}
#endif
