import Foundation
import GRDB
import SQLiteData
import LifeCore

/// A synchronized running session. Elapsed time is derived from `start`, never a background tick counter.
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

// Disposable projection of immutable timer lifecycle revisions.
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

public enum TimerLifecycleState: String, Codable, Equatable, Sendable { case running, finished, cancelled }

public struct TimerRevisionPayload: Codable, Equatable, Sendable {
    public var timer: RunningTimer
    public var state: TimerLifecycleState
    public var recordRevisionID: UUID?
    public init(timer: RunningTimer, state: TimerLifecycleState, recordRevisionID: UUID? = nil) {
        self.timer = timer; self.state = state; self.recordRevisionID = recordRevisionID
    }
}

@Table("timerRevisions")
struct TimerRevision: Sendable, Equatable {
    let id: UUID
    var timerID: String
    var payload: String
    var parentIDsJSON: String
    var createdAt: Double
    var parents: [UUID] { (try? JSONDecoder().decode([UUID].self, from: Data(parentIDsJSON.utf8))) ?? [] }
    var value: TimerRevisionPayload? { try? JSONDecoder().decode(TimerRevisionPayload.self, from: Data(payload.utf8)) }
}

private struct TimerChoice {
    var id: UUID
    var timer: TimerRevision
    var record: RecordRevision?
}

extension LifeStore {
    @discardableResult
    public func startTimer(title: String, category: String, at: Date = Date(), id: UUID = UUID()) throws -> RunningTimer {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, Self.validDate(at) else { throw LifeStoreError.invalidRecord("请填写计时事项，并使用有效的开始时间。") }
        let timer = try database.write { db in try Self.startTimer(in: db, title: title, category: category, at: at, id: id) }
        try refreshAndNotify()
        return timer
    }

    @discardableResult
    public func finishTimer(id: UUID, at: Date = Date()) throws -> TimeBlock {
        let block = try database.write { db in try Self.finishTimer(in: db, id: id, at: at) }
        try refreshAndNotify()
        return block
    }

    @discardableResult
    public func switchTimer(id: UUID, nextTitle: String, nextCategory: String, at: Date = Date(), nextID: UUID = UUID()) throws -> TimerSwitchResult {
        let title = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = nextCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, Self.validDate(at), id != nextID else { throw LifeStoreError.invalidRecord("请填写下一事项，使用有效时间和新的计时标识；原计时未结束。") }
        let result = try database.write { db in
            let tips = Self.timerTips(try TimerRevision.fetchAll(db).filter { $0.timerID == id.uuidString })
            guard tips.count <= 1 else { throw LifeStoreError.unresolvedConflict }
            if tips.first?.value?.state != .running {
                // A retry is valid only when the same successor still exists with the same boundary.
                let nextTips = Self.timerTips(try TimerRevision.fetchAll(db).filter { $0.timerID == nextID.uuidString })
                guard nextTips.count == 1, let next = nextTips.first?.value?.timer,
                      next.start == at, next.title == title, next.category == (category.isEmpty ? "未分类" : category) else {
                    throw LifeStoreError.invalidRecord("原计时已经结束，请刷新当前计时后重试。")
                }
                let finished = try Self.finishTimer(in: db, id: id, at: at)
                guard finished.end == at else { throw LifeStoreError.invalidRecord("该计时已在另一时间结束。") }
                return TimerSwitchResult(finished: finished, started: next)
            }
            guard try !TimerRevision.fetchAll(db).contains(where: { $0.timerID == nextID.uuidString }),
                  try !RecordRevision.fetchAll(db).contains(where: { $0.entityID == nextID.uuidString }) else {
                throw LifeStoreError.invalidRecord("下一计时标识已被使用；原计时未结束。")
            }
            let finished = try Self.finishTimer(in: db, id: id, at: at)
            let started = try Self.startTimer(in: db, title: title, category: category, at: at, id: nextID)
            return TimerSwitchResult(finished: finished, started: started)
        }
        try refreshAndNotify()
        return result
    }

    nonisolated private static func startTimer(in db: Database, title: String, category: String, at: Date, id: UUID) throws -> RunningTimer {
        let rows = try TimerRevision.fetchAll(db).filter { $0.timerID == id.uuidString }
        let tips = timerTips(rows)
        guard tips.count <= 1 else { throw LifeStoreError.unresolvedConflict }
        if let existing = tips.first?.value, existing.state == .running { return existing.timer }
        guard tips.isEmpty, try !RecordRevision.fetchAll(db).contains(where: { $0.entityID == id.uuidString }) else {
            throw LifeStoreError.invalidRecord("这次计时已经结束，请刷新手表后开始新的事项。")
        }
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let timer = RunningTimer(id: id, title: title, category: category.isEmpty ? "未分类" : category, start: at)
        try insertTimerRevision(db, payload: TimerRevisionPayload(timer: timer, state: .running), parents: [])
        try rebuildTimerProjection(db)
        return timer
    }

    nonisolated private static func finishTimer(in db: Database, id: UUID, at: Date) throws -> TimeBlock {
        let timerRows = try TimerRevision.fetchAll(db).filter { $0.timerID == id.uuidString }
        let tips = timerTips(timerRows)
        guard tips.count <= 1 else { throw LifeStoreError.unresolvedConflict }
        let recordTips = Self.tips(try RecordRevision.fetchAll(db).filter { $0.entityID == id.uuidString })
        guard recordTips.count <= 1 else { throw LifeStoreError.unresolvedConflict }
        guard let tip = tips.first, let lifecycle = tip.value, lifecycle.state == .running else {
            guard tips.first?.value?.state != .cancelled,
                  let current = recordTips.first, !current.isDeleted, current.entityType == "timeBlock" else {
                throw LifeStoreError.invalidRecord("找不到正在进行的计时，或该记录已删除。")
            }
            return try JSONDecoder().decode(TimeBlock.self, from: Data(current.payload.utf8))
        }
        let timer = lifecycle.timer
        guard Self.validDate(timer.start), Self.validDate(at), at > timer.start else {
            throw LifeStoreError.invalidRecord("结束时间必须晚于开始时间，且日期需有效；正在计时的事项已保留。")
        }
        let longSession = at.timeIntervalSince(timer.start) > 7 * 86400
        let block = TimeBlock(id: id, title: timer.title, category: timer.category, start: timer.start, end: at,
                              note: longSession ? "此计时超过7天，已保留完整时间；请核对实际结束时间。" : "",
                              source: .manual, status: .confirmed, evidence: "手动开始并结束的计时。")
        let recordID = try Self.insertRevision(db, entityID: id, kind: "timeBlock", payload: Self.encode(block), deleted: false, parents: recordTips.map(\.id))
        try insertTimerRevision(db, payload: TimerRevisionPayload(timer: timer, state: .finished, recordRevisionID: recordID), parents: [tip.id])
        try rebuildTimerProjection(db)
        return block
    }

    public func cancelTimer(id: UUID) throws {
        try database.write { db in
            let tips = Self.timerTips(try TimerRevision.fetchAll(db).filter { $0.timerID == id.uuidString })
            guard tips.count <= 1 else { throw LifeStoreError.unresolvedConflict }
            guard let tip = tips.first, let value = tip.value, value.state == .running else { return }
            let records = Self.tips(try RecordRevision.fetchAll(db).filter { $0.entityID == id.uuidString })
            guard records.count <= 1 else { throw LifeStoreError.unresolvedConflict }
            let recordID = try Self.insertRevision(db, entityID: id, kind: "timeBlock", payload: "{}", deleted: true, parents: records.map(\.id))
            try Self.insertTimerRevision(db, payload: TimerRevisionPayload(timer: value.timer, state: .cancelled, recordRevisionID: recordID), parents: [tip.id])
            try Self.rebuildTimerProjection(db)
        }
        try refreshAndNotify()
    }

    nonisolated static func timerTips(_ rows: [TimerRevision]) -> [TimerRevision] {
        let parents = Set(rows.flatMap(\.parents))
        return rows.filter { !parents.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    @discardableResult nonisolated static func insertTimerRevision(_ db: Database, payload: TimerRevisionPayload, parents: [UUID]) throws -> UUID {
        let row = TimerRevision(id: UUID(), timerID: payload.timer.id.uuidString, payload: try encode(payload), parentIDsJSON: try encode(parents), createdAt: Date().timeIntervalSince1970)
        try TimerRevision.insert { row }.execute(db)
        return row.id
    }
    nonisolated static func requireUnconflictedTimer(_ db: Database, id: UUID) throws {
        guard timerTips(try TimerRevision.fetchAll(db).filter { $0.timerID == id.uuidString }).count <= 1 else { throw LifeStoreError.unresolvedConflict }
    }
    nonisolated static func rebuildTimerProjection(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM timerSessions")
        for rows in Dictionary(grouping: try TimerRevision.fetchAll(db), by: \.timerID).values {
            let tips = timerTips(rows)
            guard tips.count == 1, let value = tips.first?.value, value.state == .running else { continue }
            let timer = value.timer
            let row = TimerSessionRecord(id: timer.id, title: timer.title, category: timer.category, startTimestamp: timer.start.timeIntervalSince1970)
            try TimerSessionRecord.insert { row }.execute(db)
        }
    }
    nonisolated private static func timerChoices(_ timers: [TimerRevision], records: [RecordRevision]) -> [TimerChoice] {
        let recordTips = tips(records)
        var result: [TimerChoice] = []
        func descends(_ row: RecordRevision, from ancestor: UUID) -> Bool {
            var pending = [row.id], seen = Set<UUID>()
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            while let id = pending.popLast() {
                if id == ancestor { return true }
                if seen.insert(id).inserted { pending += byID[id]?.parents ?? [] }
            }
            return false
        }
        for timer in timerTips(timers) {
            guard let value = timer.value else { continue }
            if value.state == .finished, let recordID = value.recordRevisionID {
                let descendants = recordTips.filter { descends($0, from: recordID) }
                for record in descendants { result.append(TimerChoice(id: record.id, timer: timer, record: record)) }
            } else { result.append(TimerChoice(id: timer.id, timer: timer, record: nil)) }
        }
        // Distinct lifecycle branches can point at the same record after concurrent resolutions.
        var seen = Set<UUID>()
        return result.filter { seen.insert($0.id).inserted }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func applyTimerRevisions(_ rows: [TimerRevision], records: [RecordRevision]) {
        var running: [RunningTimer] = []
        for (entity, versions) in Dictionary(grouping: rows, by: \.timerID) {
            guard let id = UUID(uuidString: entity) else { continue }
            let tips = Self.timerTips(versions)
            let entityRecords = records.filter { $0.entityID == entity }
            let choices = Self.timerChoices(versions, records: entityRecords)
            let hasConflict = tips.count > 1 || (tips.first?.value?.state == .finished && Self.tips(entityRecords).count > 1)
            if hasConflict {
                conflicts.removeAll { $0.entityID == id }
                timeBlocks.removeAll { $0.id == id }
                conflicts.append(RecordConflict(entityID: id, kind: "timer", versions: choices.map { choice in
                    let value = choice.timer.value!
                    let timer = value.timer
                    var label = "\(timer.title) · 开始 \(timer.start.formatted())"
                    if value.state == .running { label = "继续计时 · " + label }
                    else if value.state == .cancelled { label = "取消计时，不保存时间 · " + label }
                    else if let row = choice.record, row.isDeleted { label = "删除已完成的计时，不计入统计 · " + label }
                    else if let row = choice.record, let block = try? JSONDecoder().decode(TimeBlock.self, from: Data(row.payload.utf8)), Self.validDate(block.start), Self.validDate(block.end), block.end > block.start {
                        label = "已完成 · \(block.title) · 开始 \(block.start.formatted()) · 结束 \(block.end.formatted()) · \(Int(block.end.timeIntervalSince(block.start)))秒"
                    } else { label = "无法解读的完成版本 · " + label }
                    return RevisionChoice(id: choice.id, label: label, payload: choice.record?.payload ?? choice.timer.payload, isDeleted: choice.record?.isDeleted ?? (value.state == .cancelled))
                }))
            } else if let value = tips.first?.value, value.state == .running {
                running.append(value.timer)
                timeBlocks.removeAll { $0.id == id }
            } else if tips.first?.value?.state == .cancelled { timeBlocks.removeAll { $0.id == id } }
            for row in versions where row.value == nil {
                recordReadIssues.append(RecordReadIssue(id: row.id, entityID: entity, message: "计时版本无法解读，原始数据已保留。"))
            }
        }
        runningTimers = running.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        conflicts.sort { $0.entityID.uuidString < $1.entityID.uuidString }
    }
    nonisolated static func resolveTimerConflict(_ db: Database, entityID: UUID, choosing revisionID: UUID) throws -> Bool {
        let timers = try TimerRevision.fetchAll(db).filter { $0.timerID == entityID.uuidString }
        guard !timers.isEmpty else { return false }
        let timerTips = timerTips(timers)
        let records = try RecordRevision.fetchAll(db).filter { $0.entityID == entityID.uuidString }
        let recordTips = tips(records)
        guard timerTips.count > 1 || recordTips.count > 1 else { return false }
        guard let chosen = timerChoices(timers, records: records).first(where: { $0.id == revisionID }), var value = chosen.timer.value else { throw LifeStoreError.missingRevision }
        let payload = chosen.record?.payload ?? "{}"
        let deleted = value.state != .finished || chosen.record?.isDeleted == true
        let recordID = try insertRevision(db, entityID: entityID, kind: "timeBlock", payload: payload, deleted: deleted, parents: recordTips.map(\.id))
        value.recordRevisionID = recordID
        try insertTimerRevision(db, payload: value, parents: timerTips.map(\.id))
        try rebuildTimerProjection(db)
        return true
    }
}
