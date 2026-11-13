import Foundation
import GRDB
import SQLiteData
import LifeCore

/// A local running session. Elapsed time is derived from `start`, never a background tick counter.
public struct RunningTimer: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var category: String
    public var start: Date
    public init(id: UUID = UUID(), title: String, category: String, start: Date = Date()) {
        self.id = id; self.title = title; self.category = category; self.start = start
    }
}

public struct TimerSwitchResult: Equatable, Sendable {
    public let finished: TimeBlock
    public let started: RunningTimer
}

// Intentionally excluded from SyncEngine: unfinished sessions belong to this device only.
@Table("timerSessions")
struct TimerSessionRecord: Sendable {
    let id: UUID
    var title: String
    var category: String
    var startTimestamp: Double
    var timer: RunningTimer {
        RunningTimer(id: id, title: title, category: category, start: Date(timeIntervalSince1970: startTimestamp))
    }
}

extension LifeStore {
    /// Starts another independent session; existing timers continue running.
    @discardableResult
    public func startTimer(title: String, category: String, at: Date = Date(), id: UUID = UUID()) throws -> RunningTimer {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, Self.validDate(at) else {
            throw LifeStoreError.invalidRecord("请填写计时事项，并使用有效的开始时间。")
        }
        let timer = try database.write { db in
            try Self.startTimer(in: db, title: title, category: category, at: at, id: id)
        }
        try refreshAndNotify()
        return timer
    }

    /// Finishes and records a session atomically. Retrying a completed session never inserts twice.
    @discardableResult
    public func finishTimer(id: UUID, at: Date = Date()) throws -> TimeBlock {
        let block = try database.write { db in try Self.finishTimer(in: db, id: id, at: at) }
        try refreshAndNotify()
        return block
    }

    /// Ends the selected session and starts its replacement in one transaction.
    /// Supply a stable nextID when a caller may retry an interrupted request.
    @discardableResult
    public func switchTimer(id: UUID, nextTitle: String, nextCategory: String, at: Date = Date(), nextID: UUID = UUID()) throws -> TimerSwitchResult {
        let title = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = nextCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, Self.validDate(at), id != nextID else {
            throw LifeStoreError.invalidRecord("请填写下一事项，使用有效时间和新的计时标识；原计时未结束。")
        }
        let result = try database.write { db in
            let sessions = try TimerSessionRecord.fetchAll(db)
            if !sessions.contains(where: { $0.id == id }) {
                // Retry only the same already-completed switch, never create an extra next session.
                guard let next = sessions.first(where: { $0.id == nextID }), next.startTimestamp == at.timeIntervalSince1970,
                      next.title == title, next.category == (category.isEmpty ? "未分类" : category) else {
                    throw LifeStoreError.invalidRecord("原计时已经结束，请刷新当前计时后重试。")
                }
                let finished = try Self.finishTimer(in: db, id: id, at: at)
                guard finished.end == at else { throw LifeStoreError.invalidRecord("该计时已在另一时间结束。") }
                return TimerSwitchResult(finished: finished, started: next.timer)
            }
            let finished = try Self.finishTimer(in: db, id: id, at: at)
            // A colliding next ID is an error: never silently replace a separate running timer.
            guard !sessions.contains(where: { $0.id == nextID }) else {
                throw LifeStoreError.invalidRecord("下一计时标识已被使用；原计时未结束。")
            }
            let started = try Self.startTimer(in: db, title: title, category: category, at: at, id: nextID)
            return TimerSwitchResult(finished: finished, started: started)
        }
        try refreshAndNotify()
        return result
    }

    nonisolated private static func startTimer(in db: Database, title: String, category: String, at: Date, id: UUID) throws -> RunningTimer {
        // A watch retry carries the same identifier, including after either app restarts.
        if let existing = try TimerSessionRecord.fetchAll(db).first(where: { $0.id == id }) { return existing.timer }
        guard try !RecordRevision.fetchAll(db).contains(where: { $0.entityID == id.uuidString }) else {
            throw LifeStoreError.invalidRecord("这次计时已经结束，请刷新手表后开始新的事项。")
        }
        let timer = RunningTimer(id: id, title: title, category: category.isEmpty ? "未分类" : category, start: at)
        let row = TimerSessionRecord(id: id, title: timer.title, category: timer.category, startTimestamp: at.timeIntervalSince1970)
        try TimerSessionRecord.insert { row }.execute(db)
        return timer
    }

    nonisolated private static func finishTimer(in db: Database, id: UUID, at: Date) throws -> TimeBlock {
        let rows = try RecordRevision.fetchAll(db).filter { $0.entityID == id.uuidString }
        let tips = Self.tips(rows)
        guard let session = try TimerSessionRecord.fetchAll(db).first(where: { $0.id == id }) else {
            guard tips.count == 1, let current = tips.first, !current.isDeleted, current.entityType == "timeBlock" else {
                if tips.count > 1 { throw LifeStoreError.unresolvedConflict }
                throw LifeStoreError.invalidRecord("找不到正在进行的计时，或该记录已删除。")
            }
            return try JSONDecoder().decode(TimeBlock.self, from: Data(current.payload.utf8))
        }
        guard tips.isEmpty else { throw LifeStoreError.unresolvedConflict }
        let timer = session.timer
        // A forgotten timer can always be recovered with its full actual interval. The manual
        // editor's seven-day validation is intentionally separate from finishing a running session.
        guard Self.validDate(timer.start), Self.validDate(at), at > timer.start else {
            throw LifeStoreError.invalidRecord("结束时间必须晚于开始时间，且日期需有效；正在计时的事项已保留。")
        }
        let longSession = at.timeIntervalSince(timer.start) > 7 * 86400
        let block = TimeBlock(id: id, title: timer.title, category: timer.category, start: timer.start, end: at,
                              note: longSession ? "此计时超过7天，已保留完整时间；请核对实际结束时间。" : "",
                              source: .manual, status: .confirmed, evidence: "手动开始并结束的计时。")
        try Self.insert(db, entityID: id, kind: "timeBlock", payload: Self.encode(block), deleted: false, parents: [], origin: "manual")
        try TimerSessionRecord.find(id).delete().execute(db)
        return block
    }

    /// Discards only the unfinished local session; does not delete an existing recorded TimeBlock.
    public func cancelTimer(id: UUID) throws {
        try database.write { db in
            guard try TimerSessionRecord.fetchAll(db).contains(where: { $0.id == id }) else { return }
            // Remember cancelled start IDs so a delayed watch retry cannot restart them.
            // A deleted revision carries no task content and adds no recorded time.
            try Self.insert(db, entityID: id, kind: "timeBlock", payload: "{}", deleted: true, parents: [], origin: "manual")
            try TimerSessionRecord.find(id).delete().execute(db)
        }
        try refreshAndNotify()
    }
}
