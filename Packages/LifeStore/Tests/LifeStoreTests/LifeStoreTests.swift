import Foundation
import Testing
import LifeCore
import SQLiteData
@testable import LifeStore

@MainActor struct LifeStoreTests {
    func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("LifeStoreTests-\(UUID()).sqlite") }
    func transaction(id: UUID = UUID(), amount: Int = 1234) -> LifeCore.Transaction {
        .init(id: id, amountCents: amount, kind: .expense, category: "餐饮", merchant: "午餐")
    }
    @Test func durableEditDeleteAndReopen() throws {
        let path = url()
        let first = try LifeStore(databaseURL: path)
        var value = transaction()
        try first.save(value)
        value.amountCents = 2000
        try first.save(value)
        let reopened = try LifeStore(databaseURL: path)
        #expect(reopened.transactions == [value])
        try reopened.deleteTransaction(id: value.id)
        #expect(try LifeStore(databaseURL: path).transactions.isEmpty)
        let database = try DatabaseQueue(path: path.path)
        #expect(try database.read { try RecordRevision.fetchAll($0).count } == 3)
    }
    @Test func divergentBranchesRequireExplicitResolution() throws {
        let path = url(), value = transaction()
        let store = try LifeStore(databaseURL: path)
        try store.save(value)
        let database = try DatabaseQueue(path: path.path)
        let original = try database.read { try RecordRevision.fetchAll($0)[0] }
        var other = value; other.amountCents = 9999
        try database.write { db in
            try LifeStore.insert(db, entityID: value.id, kind: "transaction", payload: LifeStore.encode(other), deleted: false, parents: [original.id])
            try LifeStore.insert(db, entityID: value.id, kind: "transaction", payload: "", deleted: true, parents: [original.id])
        }
        try store.refresh()
        #expect(store.transactions.isEmpty)
        #expect(store.conflicts.count == 1)
        #expect(throws: LifeStoreError.self) { try store.save(value) }
        let deletion = try #require(store.conflicts[0].versions.first { $0.isDeleted })
        try store.resolveConflict(entityID: value.id, choosing: deletion.id)
        #expect(store.conflicts.isEmpty)
        #expect(store.transactions.isEmpty)
        #expect(try LifeStore(databaseURL: path).transactions.isEmpty)
    }
    @Test func screenDedupPreservesCorrectionsAndDeletion() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var summary = ScreenSummary(id: "query-A", title: "写作", category: "创作", start: start, end: start.addingTimeInterval(600), summary: "草稿")
        try store.importScreenSummaries([summary, summary])
        #expect(store.timeBlocks.count == 1)
        var corrected = store.timeBlocks[0]; corrected.title = "备课"; corrected.status = .confirmed
        try store.save(corrected)
        summary.id = "query-B"; summary.title = "模型新标题"
        try store.importScreenSummaries([summary])
        #expect(store.timeBlocks == [corrected])
        try store.deleteTimeBlock(id: corrected.id)
        try store.importScreenSummaries([summary])
        #expect(store.timeBlocks.isEmpty)
    }
    @Test func rawLocationEvidenceStaysLocalAndVisitsDeduplicate() throws {
        let path = url(), store = try LifeStore(databaseURL: path)
        let data = Data(#"{"locations":[{"type":"Feature","geometry":{"type":"Point","coordinates":[120,30]},"properties":{"timestamp":"2026-11-12T01:00:00Z"}},{"type":"Feature","properties":{"arrival_date":"2026-11-12T01:00:00Z","departure_date":"2026-11-12T02:00:00Z"}},{"properties":{"arrival_date":"2026-11-12T01:00:00Z","departure_date":"4001-01-01T00:00:00Z"}}]}"#.utf8)
        try store.importLocationFeatures(data)
        try store.importLocationFeatures(data)
        #expect(store.timeBlocks.count == 1)
        #expect(store.timeBlocks[0].status == .pending)
        #expect(!store.timeBlocks[0].evidence.contains("120"))
        let database = try DatabaseQueue(path: path.path)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM locationEvidence") } == 3)
        #expect(try database.read { try RecordRevision.fetchAll($0).count } == 1)
    }
    @Test func incompleteVisitDoesNotInventTask() throws {
        let store = try LifeStore(databaseURL: url())
        try store.importLocationFeatures(Data(#"{"locations":[{"properties":{"arrival_date":"2026-11-12T01:00:00Z","departure_date":"4001-01-01T00:00:00Z"}}]}"#.utf8))
        #expect(store.timeBlocks.isEmpty)
        #expect(throws: (any Error).self) { try store.importLocationFeatures(Data("{}".utf8)) }
    }
    @Test func localOnlySyncIsTruthful() async throws {
        let store = try LifeStore(databaseURL: url())
        await store.requestSync()
        #expect(store.syncStatus.contains("仅本机"))
        #expect(store.errorMessage == nil)
    }
}

@MainActor struct ScreenReconciliationTests {
    @Test func sourceSnapshotDeletesOnlyUntouchedDrafts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenSnapshot-\(UUID()).sqlite")
        let store = try LifeStore(databaseURL: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000), end = start.addingTimeInterval(3600)
        let one = ScreenSummary(id: "1", title: "一", category: "工作", start: start, end: start.addingTimeInterval(600), summary: "", deviceID: "test")
        let two = ScreenSummary(id: "2", title: "二", category: "工作", start: start.addingTimeInterval(1200), end: start.addingTimeInterval(1800), summary: "", deviceID: "test")
        try store.importScreenSummaries([one, two], windowStart: start, windowEnd: end, deviceID: "test")
        #expect(store.timeBlocks.count == 2)
        var confirmed = try #require(store.timeBlocks.first { $0.title == "二" }); confirmed.status = .confirmed
        try store.save(confirmed)
        try store.importScreenSummaries([], windowStart: start, windowEnd: end, deviceID: "test")
        #expect(store.timeBlocks == [confirmed])
        var shifted = two; shifted.id = "changed"; shifted.start = shifted.start.addingTimeInterval(60)
        try store.importScreenSummaries([shifted], windowStart: start, windowEnd: end, deviceID: "test")
        #expect(store.timeBlocks == [confirmed])
    }
}

@MainActor struct StoreObservationTests {
    @Test func anotherConnectionRefreshesPublishedRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoreObservation-\(UUID()).sqlite")
        let observing = try LifeStore(databaseURL: url), writing = try LifeStore(databaseURL: url)
        let value = LifeCore.Transaction(amountCents: 600, kind: .expense, category: "餐饮", merchant: "早餐")
        try writing.save(value)
        for _ in 0..<50 {
            if observing.transactions == [value] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(observing.transactions == [value])
    }
    @Test func unsignedCloudConfigurationStaysLocal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UnsignedCloud-\(UUID()).sqlite")
        let store = try LifeStore(databaseURL: url, cloudContainerIdentifier: "iCloud.invalid.LifeRecordTests")
        await store.requestSync()
        #expect(store.syncStatus.contains("仅本机"))
        #expect(!store.syncStatus.contains("请求已完成"))
    }
}

@MainActor struct StaleEditorTests {
    @Test func staleAmountCannotOverwriteNewerEdit() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("StaleEdit-\(UUID()).sqlite")
        let store = try LifeStore(databaseURL: path)
        let original = LifeCore.Transaction(amountCents: 10000, kind: .expense, category: "购物", merchant: "测试")
        try store.save(original, ifUnchangedFrom: nil)
        var newer = original; newer.amountCents = 20000
        try store.save(newer, ifUnchangedFrom: original)
        var stale = original; stale.note = "旧窗口改备注"
        #expect(throws: LifeStoreError.self) { try store.save(stale, ifUnchangedFrom: original) }
        #expect(store.transactions == [newer])
        #expect(throws: LifeStoreError.self) { try store.deleteTransaction(id: original.id, ifUnchangedFrom: original) }
        #expect(store.transactions == [newer])
    }
    @Test func deletedEntryCannotBeResurrectedByOldForm() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("StaleDelete-\(UUID()).sqlite")
        let store = try LifeStore(databaseURL: path)
        let original = LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: "测试")
        try store.save(original, ifUnchangedFrom: nil)
        try store.deleteTransaction(id: original.id, ifUnchangedFrom: original)
        #expect(throws: LifeStoreError.self) { try store.save(original, ifUnchangedFrom: original) }
        #expect(store.transactions.isEmpty)
    }
    @Test func staleTimeEditorCannotOverwriteNewerTime() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("StaleTime-\(UUID()).sqlite")
        let store = try LifeStore(databaseURL: path)
        let old = TimeBlock(title: "备课", category: "工作", start: Date().addingTimeInterval(-3600), end: Date())
        try store.save(old, ifUnchangedFrom: nil)
        var next = old; next.title = "教学复盘"
        try store.save(next, ifUnchangedFrom: old)
        #expect(throws: LifeStoreError.self) { try store.save(old, ifUnchangedFrom: old) }
        #expect(store.timeBlocks == [next])
    }
}

