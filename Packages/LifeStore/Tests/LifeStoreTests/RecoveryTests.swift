import Foundation
import Testing
import LifeCore
import SQLiteData
@testable import LifeStore

@MainActor struct RecoveryTests {
    func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-\(UUID()).sqlite") }
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func forgottenTimerCanFinishFullIntervalAfterReopen() throws {
        let path = url(), first = try LifeStore(databaseURL: path)
        let timer = try first.startTimer(title: "忘记结束", category: "工作", at: start)
        let reopened = try LifeStore(databaseURL: path)
        let end = start.addingTimeInterval(12 * 86400 + 123)
        let block = try reopened.finishTimer(id: timer.id, at: end)
        #expect(block.start == start)
        #expect(block.end == end)
        #expect(block.end.timeIntervalSince(block.start) == 12 * 86400 + 123)
        #expect(block.note.contains("完整时间"))
        #expect(reopened.runningTimers.isEmpty)
        #expect(try LifeStore(databaseURL: path).timeBlocks == [block])
        #expect(try reopened.finishTimer(id: timer.id, at: end.addingTimeInterval(60)) == block)
        // Existing recovered timers remain editable; new long manual entries are still rejected.
        var manuallyCreated = block
        manuallyCreated.id = UUID()
        #expect(throws: LifeStoreError.self) { try reopened.save(manuallyCreated) }
    }
    @Test func longCompletedTimerCanEditNotesAndShortenButCannotExpand() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let timer = try store.startTimer(title: "长计时", category: "工作", at: start)
        let original = try store.finishTimer(id: timer.id, at: start.addingTimeInterval(12 * 86400))
        var edited = original; edited.note = "补充说明"
        try store.save(edited, ifUnchangedFrom: original)
        #expect(store.timeBlocks == [edited])
        var shortened = edited
        shortened.start = start.addingTimeInterval(86400)
        shortened.end = start.addingTimeInterval(10 * 86400)
        try store.save(shortened, ifUnchangedFrom: edited)
        #expect(shortened.end.timeIntervalSince(shortened.start) == 9 * 86400)
        #expect(try LifeStore(databaseURL: path).timeBlocks == [shortened])
        var notesOnly = shortened; notesOnly.note = "普通保存路径也可以"
        try store.save(notesOnly)
        #expect(store.timeBlocks == [notesOnly])
        #expect(throws: LifeStoreError.self) { try store.save(edited) }
        var shifted = notesOnly
        shifted.start = shifted.start.addingTimeInterval(-1)
        shifted.end = shifted.end.addingTimeInterval(-1)
        #expect(throws: LifeStoreError.self) { try store.save(shifted) }
        var invalid = notesOnly; invalid.end = invalid.start
        #expect(throws: LifeStoreError.self) { try store.save(invalid) }
        #expect(store.timeBlocks == [notesOnly])
        var copied = notesOnly; copied.id = UUID()
        #expect(throws: LifeStoreError.self) { try store.save(copied, ifUnchangedFrom: nil) }
        #expect(try LifeStore(databaseURL: path).timeBlocks == [notesOnly])
    }
    @Test func atomicSwitchUsesSameBoundaryAndLeavesParallelTimerAlone() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let old = try store.startTimer(title: "备课", category: "工作", at: start)
        let parallel = try store.startTimer(title: "通勤", category: "出行", at: start)
        let nextID = UUID(), boundary = start.addingTimeInterval(90)
        let result = try store.switchTimer(id: old.id, nextTitle: "阅读", nextCategory: "学习", at: boundary, nextID: nextID)
        #expect(result.finished.id == old.id)
        #expect(result.finished.end == boundary)
        #expect(result.started.start == boundary)
        #expect(result.started.id == nextID)
        #expect(Set(store.runningTimers.map(\.id)) == [nextID, parallel.id])
        let reopened = try LifeStore(databaseURL: path)
        #expect(try reopened.switchTimer(id: old.id, nextTitle: "阅读", nextCategory: "学习", at: boundary, nextID: nextID) == result)
        #expect(reopened.timeBlocks == [result.finished])
    }
    @Test func switchFailureRollsBackAlreadyPreparedFinish() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let old = try store.startTimer(title: "原事项", category: "工作", at: start)
        // A used ledger ID fails inside startTimer, after finishTimer has inserted a revision.
        let used = try store.startTimer(title: "已结束", category: "工作", at: start)
        try store.finishTimer(id: used.id, at: start.addingTimeInterval(10))
        #expect(throws: LifeStoreError.self) {
            try store.switchTimer(id: old.id, nextTitle: "下一项", nextCategory: "工作", at: start.addingTimeInterval(60), nextID: used.id)
        }
        #expect(store.runningTimers == [old])
        #expect(store.timeBlocks.count == 1)
        let reopened = try LifeStore(databaseURL: path)
        #expect(reopened.runningTimers == [old])
        #expect(!reopened.timeBlocks.contains { $0.id == old.id })
        for (title, end) in [(" \n", start.addingTimeInterval(60)), ("下一项", start)] {
            #expect(throws: LifeStoreError.self) { try store.switchTimer(id: old.id, nextTitle: title, nextCategory: "", at: end) }
            #expect(store.runningTimers == [old])
        }
    }
    @Test func malformedPayloadIsIsolatedWithoutLosingHealthyRecordsOrRawData() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let good = LifeCore.Transaction(amountCents: 1234, kind: .expense, category: "餐饮", merchant: "午餐")
        try store.save(good)
        let badID = UUID(), db = try DatabaseQueue(path: path.path)
        let raw = "{broken JSON"
        try db.write { db in
            try LifeStore.insert(db, entityID: badID, kind: "transaction", payload: raw, deleted: false, parents: [])
        }
        let reopened = try LifeStore(databaseURL: path)
        #expect(reopened.transactions == [good])
        #expect(reopened.recordReadIssues.count == 1)
        #expect(reopened.recordReadIssues.first?.entityID == badID.uuidString)
        #expect(reopened.errorMessage?.contains("原始数据库未删除") == true)
        #expect(try db.read { try RecordRevision.fetchAll($0).first { $0.entityID == badID.uuidString }?.payload } == raw)
        let timer = try reopened.startTimer(title: "计时仍可用", category: "工作", at: start)
        #expect(reopened.runningTimers == [timer])
        #expect(reopened.transactions == [good])
        #expect(reopened.errorMessage != nil)
        try reopened.refresh()
        #expect(reopened.recordReadIssues.count == 1)
    }
}
