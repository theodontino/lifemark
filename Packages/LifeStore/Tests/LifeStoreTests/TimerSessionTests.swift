import Foundation
import Testing
import LifeCore
import SQLiteData
@testable import LifeStore

@MainActor struct TimerSessionTests {
    func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("TimerSessions-\(UUID()).sqlite") }
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func survivesReopenWithOriginalStart() throws {
        let path = url()
        let first = try LifeStore(databaseURL: path)
        let timer = try first.startTimer(title: " 备课 ", category: "工作", at: start)
        let reopened = try LifeStore(databaseURL: path)
        #expect(reopened.runningTimers == [timer])
        #expect(reopened.runningTimers.first?.start == start)
        #expect(timer.title == "备课")
        #expect(reopened.timeBlocks.isEmpty)
    }
    @Test func finishingCommitsExactDurationAndRemovesSession() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let timer = try store.startTimer(title: "阅读", category: "学习", at: start)
        let block = try store.finishTimer(id: timer.id, at: start.addingTimeInterval(123.5))
        #expect(block.id == timer.id)
        #expect(block.end.timeIntervalSince(block.start) == 123.5)
        #expect(block.status == .confirmed)
        #expect(block.source == .manual)
        #expect(store.runningTimers.isEmpty)
        #expect(store.timeBlocks == [block])
        let reopened = try LifeStore(databaseURL: path)
        #expect(reopened.runningTimers.isEmpty)
        #expect(reopened.timeBlocks == [block])
    }
    @Test func parallelSessionsAreIndependentAndCanStartNext() throws {
        let store = try LifeStore(databaseURL: url())
        let a = try store.startTimer(title: "阅读", category: "学习", at: start)
        let b = try store.startTimer(title: "通勤", category: "出行", at: start.addingTimeInterval(5))
        #expect(store.runningTimers.count == 2)
        try store.finishTimer(id: a.id, at: start.addingTimeInterval(60))
        #expect(store.runningTimers == [b])
        let c = try store.startTimer(title: "写作", category: "创作", at: start.addingTimeInterval(60))
        #expect(Set(store.runningTimers.map(\.id)) == [b.id, c.id])
        #expect(store.timeBlocks.count == 1)
    }
    @Test func repeatedFinishReturnsOriginalWithoutDuplicateRevision() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let timer = try store.startTimer(title: "跑步", category: "运动", at: start)
        let original = try store.finishTimer(id: timer.id, at: start.addingTimeInterval(600))
        let reopened = try LifeStore(databaseURL: path)
        let repeated = try reopened.finishTimer(id: timer.id, at: start.addingTimeInterval(900))
        #expect(repeated == original)
        #expect(reopened.timeBlocks.count == 1)
        let db = try DatabaseQueue(path: path.path)
        #expect(try db.read { try RecordRevision.fetchAll($0).count } == 1)
    }
    @Test func invalidEndKeepsSessionAndDoesNotWriteRecord() throws {
        let store = try LifeStore(databaseURL: url())
        #expect(throws: LifeStoreError.self) { try store.startTimer(title: " \n ", category: "", at: start) }
        #expect(store.runningTimers.isEmpty)
        let timer = try store.startTimer(title: "备课", category: "", at: start)
        #expect(timer.category == "未分类")
        for end in [start, start.addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity)] {
            #expect(throws: LifeStoreError.self) { try store.finishTimer(id: timer.id, at: end) }
            #expect(store.runningTimers == [timer])
            #expect(store.timeBlocks.isEmpty)
        }
    }
    @Test func cancelOnlyDiscardsUnfinishedSession() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let a = try store.startTimer(title: "取消", category: "工作", at: start)
        let b = try store.startTimer(title: "保存", category: "工作", at: start)
        try store.cancelTimer(id: a.id)
        #expect(store.runningTimers == [b])
        #expect(throws: LifeStoreError.self) { try store.finishTimer(id: a.id, at: start.addingTimeInterval(10)) }
        let block = try store.finishTimer(id: b.id, at: start.addingTimeInterval(10))
        try store.cancelTimer(id: b.id)
        #expect(store.timeBlocks == [block])
        #expect(try LifeStore(databaseURL: path).runningTimers.isEmpty)
    }
    @Test func anotherConnectionSeesTimerAndCompletedRecordTogether() async throws {
        let path = url(), first = try LifeStore(databaseURL: path), second = try LifeStore(databaseURL: path)
        let timer = try first.startTimer(title: "读书", category: "学习", at: start)
        for _ in 0..<100 where second.runningTimers.isEmpty { await Task.yield() }
        #expect(second.runningTimers == [timer])
        try first.finishTimer(id: timer.id, at: start.addingTimeInterval(60))
        for _ in 0..<100 where second.timeBlocks.isEmpty { await Task.yield() }
        #expect(second.runningTimers.isEmpty)
        #expect(second.timeBlocks.count == 1)
    }
    @Test func watchStartRetryAfterReopenCannotDuplicateOrResurrect() throws {
        let path = url(), store = try LifeStore(databaseURL: path), id = UUID()
        let original = try store.startTimer(title: "备课", category: "工作", at: start, id: id)
        let reopened = try LifeStore(databaseURL: path)
        let retry = try reopened.startTimer(title: "备课", category: "工作", at: start.addingTimeInterval(30), id: id)
        #expect(retry == original)
        #expect(reopened.runningTimers == [original])
        try reopened.finishTimer(id: id, at: start.addingTimeInterval(60))
        #expect(throws: LifeStoreError.self) {
            try reopened.startTimer(title: "备课", category: "工作", at: start.addingTimeInterval(90), id: id)
        }
        #expect(reopened.runningTimers.isEmpty)
        #expect(reopened.timeBlocks.count == 1)
    }
    @Test func watchRetryCannotRestartCancelledTimer() throws {
        let path = url(), store = try LifeStore(databaseURL: path), id = UUID()
        try store.startTimer(title: "备课", category: "工作", at: start, id: id)
        try store.cancelTimer(id: id)
        try store.cancelTimer(id: id)
        let reopened = try LifeStore(databaseURL: path)
        #expect(throws: LifeStoreError.self) {
            try reopened.startTimer(title: "备课", category: "工作", at: start.addingTimeInterval(90), id: id)
        }
        #expect(reopened.runningTimers.isEmpty)
        #expect(reopened.timeBlocks.isEmpty)
    }

}
