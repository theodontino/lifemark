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

    /// Converts both current Chinese labels and the upstream defaults into LifeRecord's vocabulary.
    nonisolated static func lifeCategory(for raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "工作", "work", "communication", "coding / debugging", "code review",
             "engineering / product", "research & strategy", "data & insights",
             "specs & planning", "analysis & modeling", "data engineering": return "工作"
        case "学习", "study", "studying", "learning", "research", "assignments",
             "research & analysis": return "学习"
        case "创作", "creation", "creative", "design", "writing": return "创作"
        case "通勤", "commute", "commuting", "transport": return "通勤"
        case "生活", "personal", "life": return "生活"
        case "娱乐", "distraction", "entertainment", "leisure": return "娱乐"
        case "休息", "rest", "sleep": return "休息"
        default: return "待分类"
        }
    }

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
            let idleCategoryName = CategoryStore.shared.idleCategory?.name
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
                    // Exclude only the source's system Idle cards. Still reconcile the complete
                    // successful snapshot, even when empty, so LifeStore preserves manual edits.
                    return try rows.compactMap { row -> ScreenSummary? in
                        if let category: String = row["category"], let idleCategoryName,
                           category.trimmingCharacters(in: .whitespacesAndNewlines)
                            .caseInsensitiveCompare(idleCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
                            return nil
                        }
                        guard let id: Int64 = row["id"], let start: Int = row["start_ts"],
                              let end: Int = row["end_ts"], end > start,
                              let title: String = row["title"], let category: String = row["category"] else {
                            throw NSError(domain: "LifeRecord.DayflowImport", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "屏幕摘要数据不完整，本次未覆盖已有记录。"])
                        }
                        return ScreenSummary(id: String(id), title: title, category: Self.lifeCategory(for: category),
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
