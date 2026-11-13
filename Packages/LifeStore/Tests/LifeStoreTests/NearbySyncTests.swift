import Foundation
import Testing
import LifeCore
import SQLiteData
import GRDB
@testable import LifeStore

@MainActor struct NearbySyncTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Nearby-\(UUID())/LifeRecord.sqlite") }
    func store() throws -> LifeStore { try LifeStore(databaseURL: url()) }
    func send(_ a: LifeStore, _ b: LifeStore, limit: Int = 256, maxBytes: Int = 4 * 1024 * 1024) throws {
        for _ in 0..<1000 {
            let batch = try a.exportBatch(excluding: b.inventory(), limit: limit, maxBytes: maxBytes)
            try b.importBatch(batch)
            if !batch.hasMore { return }
            #expect(!batch.isEmpty)
        }
        Issue.record("分页没有终止")
    }
    func merge(_ a: LifeStore, _ b: LifeStore) throws { try send(a, b); try send(b, a) }

    @Test func incrementalAllHistoryAndRetryAreIdempotent() throws {
        let a = try store(), b = try store()
        var entry = LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: "原始")
        try a.save(entry)
        for i in 0..<20 { entry.merchant = "修改\(i)"; try a.save(entry) }
        let before = b.changeGeneration
        let first = try a.exportBatch(excluding: b.inventory(), limit: 3, maxBytes: 2500)
        #expect(try JSONEncoder().encode(first).count <= 2500)
        #expect(first.recordRevisions.count <= 3)
        let imported = try b.importBatch(first)
        #expect(imported.hasChanges)
        #expect(b.changeGeneration == before + 1)
        let generation = b.changeGeneration
        let repeated = try b.importBatch(first)
        #expect(!repeated.hasChanges)
        #expect(repeated.duplicateCount == first.recordRevisions.count)
        #expect(b.changeGeneration == generation)
        try send(a, b, limit: 3, maxBytes: 2500)
        #expect(b.transactions == [entry])
        #expect(try a.inventory() == b.inventory())
        #expect(try a.inventory().recordRevisionIDs.count == 21)
        #expect(try a.exportBatch(excluding: b.inventory()).isEmpty)
    }
    @Test func conflictingOfflineEditsAndDeleteConvergeOnlyAfterChoice() throws {
        let a = try store(), b = try store()
        var entry = LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: "午餐")
        try a.save(entry); try send(a, b)
        let base = entry
        entry.amountCents = 200; try a.save(entry, ifUnchangedFrom: base)
        try b.deleteTransaction(id: entry.id, ifUnchangedFrom: base)
        try merge(a, b)
        #expect(a.transactions.isEmpty && b.transactions.isEmpty)
        #expect(a.conflicts.count == 1 && b.conflicts.count == 1)
        let deleted = try #require(a.conflicts[0].versions.first { $0.isDeleted })
        try a.resolveConflict(entityID: entry.id, choosing: deleted.id)
        try merge(a, b)
        #expect(a.conflicts.isEmpty && b.conflicts.isEmpty)
        #expect(a.transactions.isEmpty && b.transactions.isEmpty)
        #expect(try a.inventory() == b.inventory())
    }
    @Test func timersSynchronizeWithoutResettingStartAndFinishPairIsIndivisible() throws {
        let a = try store(), b = try store()
        let timer = try a.startTimer(title: "备课", category: "工作", at: start)
        try send(a, b)
        #expect(b.runningTimers == [timer])
        let block = try a.finishTimer(id: timer.id, at: start.addingTimeInterval(60))
        #expect(throws: LifeStoreError.self) { try a.exportBatch(excluding: b.inventory(), limit: 1) }
        let batch = try a.exportBatch(excluding: b.inventory(), limit: 2)
        #expect(batch.timerRevisions.count == 1 && batch.recordRevisions.count == 1)
        try b.importBatch(batch)
        #expect(b.runningTimers.isEmpty)
        #expect(b.timeBlocks == [block])
        let generation = b.changeGeneration
        try b.importBatch(batch)
        #expect(b.changeGeneration == generation)
        #expect(try b.finishTimer(id: timer.id, at: start.addingTimeInterval(500)) == block)
        #expect(throws: LifeStoreError.self) { try b.startTimer(title: "延迟重试", category: "", at: start, id: timer.id) }
    }
    @Test func finishVersusCancelShowsOneConflictAndAtomicallyResolvesBothChains() throws {
        let a = try store(), b = try store()
        let timer = try a.startTimer(title: "写作", category: "创作", at: start)
        try send(a, b)
        let block = try a.finishTimer(id: timer.id, at: start.addingTimeInterval(60))
        try b.cancelTimer(id: timer.id)
        try merge(a, b)
        for target in [a, b] {
            #expect(target.runningTimers.isEmpty && target.timeBlocks.isEmpty)
            #expect(target.conflicts.count == 1)
            #expect(target.conflicts.first?.kind == "timer")
            #expect(target.conflicts.first?.versions.count == 2)
            #expect(throws: LifeStoreError.self) { try target.finishTimer(id: timer.id, at: start.addingTimeInterval(90)) }
            #expect(throws: LifeStoreError.self) { try target.save(block) }
        }
        let finished = try #require(a.conflicts[0].versions.first { $0.label.hasPrefix("已完成") })
        try a.resolveConflict(entityID: timer.id, choosing: finished.id)
        #expect(a.conflicts.isEmpty && a.runningTimers.isEmpty && a.timeBlocks == [block])
        try merge(a, b)
        #expect(b.conflicts.isEmpty && b.runningTimers.isEmpty && b.timeBlocks == [block])
        #expect(try a.inventory() == b.inventory())
    }
    @Test func choosingCancelPreservesBothHistoriesAndNeverRestartsOnRetry() throws {
        let a = try store(), b = try store()
        let timer = try a.startTimer(title: "取消", category: "工作", at: start)
        try send(a, b)
        try a.finishTimer(id: timer.id, at: start.addingTimeInterval(60)); try b.cancelTimer(id: timer.id)
        try merge(a, b)
        let cancel = try #require(b.conflicts[0].versions.first { $0.label.hasPrefix("取消") })
        try b.resolveConflict(entityID: timer.id, choosing: cancel.id); try merge(a, b)
        #expect(a.timeBlocks.isEmpty && b.timeBlocks.isEmpty && a.runningTimers.isEmpty && b.runningTimers.isEmpty)
        #expect(a.conflicts.isEmpty && b.conflicts.isEmpty)
        #expect(try a.inventory().recordRevisionIDs.count == 3)
        #expect(try a.inventory().timerRevisionIDs.count == 4)
        #expect(throws: LifeStoreError.self) { try a.startTimer(title: "旧手表请求", category: "工作", at: start, id: timer.id) }
    }
    @Test func dualFinishKeepsManualEditsAndIndependentParallelTimers() throws {
        let a = try store(), b = try store()
        let timer = try a.startTimer(title: "长计时", category: "工作", at: start)
        try send(a, b)
        var long = try a.finishTimer(id: timer.id, at: start.addingTimeInterval(12 * 86400))
        let base = long; long.note = "后来补充"; try a.save(long, ifUnchangedFrom: base)
        try b.finishTimer(id: timer.id, at: start.addingTimeInterval(60))
        let independent = try b.startTimer(title: "并行", category: "工作", at: start)
        try merge(a, b)
        #expect(a.runningTimers == [independent] && b.runningTimers == [independent])
        #expect(a.conflicts.count == 1 && a.timeBlocks.isEmpty)
        let selected = try #require(a.conflicts[0].versions.first { $0.payload.contains("后来补充") })
        try a.resolveConflict(entityID: timer.id, choosing: selected.id); try merge(a, b)
        #expect(b.timeBlocks == [long])
        #expect(b.runningTimers == [independent])
        var shortened = long; shortened.end = start.addingTimeInterval(9 * 86400)
        try b.save(shortened, ifUnchangedFrom: long)
        #expect(throws: LifeStoreError.self) { try b.save(long, ifUnchangedFrom: long) }
        #expect(throws: LifeStoreError.self) { try b.save(long) }
    }
    @Test func twoOfflineSwitchSuccessorsRemainParallelAfterOldTimerResolution() throws {
        let a = try store(), b = try store()
        let old = try a.startTimer(title: "原任务", category: "工作", at: start)
        try send(a, b)
        let aa = try a.switchTimer(id: old.id, nextTitle: "后继甲", nextCategory: "工作", at: start.addingTimeInterval(60), nextID: UUID())
        let bb = try b.switchTimer(id: old.id, nextTitle: "后继乙", nextCategory: "工作", at: start.addingTimeInterval(90), nextID: UUID())
        try merge(a, b)
        #expect(Set(a.runningTimers.map(\.id)) == [aa.started.id, bb.started.id])
        #expect(a.conflicts.count == 1 && a.timeBlocks.isEmpty)
        let choice = try #require(a.conflicts[0].versions.first)
        try a.resolveConflict(entityID: old.id, choosing: choice.id); try merge(a, b)
        #expect(Set(b.runningTimers.map(\.id)) == [aa.started.id, bb.started.id])
        #expect(b.conflicts.isEmpty && b.timeBlocks.count == 1)
    }
    @Test func independentStartsAndConcurrentResolutionsConverge() throws {
        let a = try store(), b = try store(), id = UUID()
        try a.startTimer(title: "甲", category: "工作", at: start, id: id)
        try b.startTimer(title: "乙", category: "工作", at: start, id: id)
        try merge(a, b)
        #expect(a.runningTimers.isEmpty && a.conflicts.count == 1)
        let options = a.conflicts[0].versions
        try a.resolveConflict(entityID: id, choosing: options[0].id)
        try b.resolveConflict(entityID: id, choosing: options[1].id)
        try merge(a, b)
        #expect(a.conflicts.count == 1 && a.runningTimers.isEmpty)
        try a.resolveConflict(entityID: id, choosing: try #require(a.conflicts[0].versions.first).id)
        try merge(a, b)
        #expect(a.conflicts.isEmpty && b.conflicts.isEmpty && a.runningTimers == b.runningTimers)
        #expect(a.runningTimers.count == 1 && a.timeBlocks.isEmpty)
    }
    @Test func badEnvelopeGraphsAndUUIDCollisionRollBackWholeBatch() throws {
        let a = try store(), b = try store()
        try a.save(LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: "午餐"))
        let batch = try a.exportBatch(excluding: b.inventory())
        var bad = batch; bad.protocolVersion = 99
        #expect(throws: LifeStoreError.self) { try b.importBatch(bad) }
        #expect(try b.inventory().recordRevisionIDs.isEmpty)
        bad = batch; bad.recordRevisions[0].parentIDs = [UUID()]
        #expect(throws: LifeStoreError.self) { try b.importBatch(bad) }
        #expect(b.transactions.isEmpty)
        bad = batch; bad.recordRevisions.append(bad.recordRevisions[0])
        #expect(throws: LifeStoreError.self) { try b.importBatch(bad) }
        try b.importBatch(batch)
        let original = try b.inventory()
        bad = batch; bad.recordRevisions[0].payload = "different"
        var fresh = batch.recordRevisions[0]; fresh.id = UUID(); fresh.entityID = UUID()
        bad.recordRevisions.insert(fresh, at: 0)
        #expect(throws: LifeStoreError.self) { try b.importBatch(bad) }
        #expect(try b.inventory() == original)
        let c = try store()
        var cycle = batch.recordRevisions[0], second = batch.recordRevisions[0]
        second.id = UUID(); cycle.parentIDs = [second.id]; second.parentIDs = [cycle.id]
        #expect(throws: LifeStoreError.self) { try c.importBatch(SyncBatch(recordRevisions: [cycle, second])) }
        #expect(try c.inventory().recordRevisionIDs.isEmpty)
        let t = try a.startTimer(title: "计时", category: "", at: start)
        try a.finishTimer(id: t.id, at: start.addingTimeInterval(5))
        let full = try a.exportBatch(excluding: c.inventory())
        let missingRecord = SyncBatch(timerRevisions: full.timerRevisions)
        #expect(throws: LifeStoreError.self) { try c.importBatch(missingRecord) }
        #expect(try c.inventory().timerRevisionIDs.isEmpty)
    }
    @Test func opaqueDamagedPayloadIsPreservedAndIsolatedBesideHealthyRecords() throws {
        let a = try store(), b = try store()
        try a.save(LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: "健康记录"))
        let badID = UUID(), raw = "{broken JSON, 原文"
        try a.database.write { db in try LifeStore.insert(db, entityID: badID, kind: "transaction", payload: raw, deleted: false, parents: []) }
        try a.refresh(); try send(a, b)
        #expect(b.transactions.count == 1 && b.recordReadIssues.count == 1)
        let exported = try b.exportBatch(excluding: SyncInventory())
        #expect(exported.recordRevisions.first { $0.entityID == badID }?.payload == raw)
        #expect(b.errorMessage?.contains("原始数据库未删除") == true)
    }
    @Test func byteLimitIsExactAndOversizedRecordIsExplicit() throws {
        let a = try store(), b = try store()
        for _ in 0..<8 { try a.save(LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: String(repeating: "中文", count: 80))) }
        let batch = try a.exportBatch(excluding: b.inventory(), maxBytes: 3000)
        #expect(try JSONEncoder().encode(batch).count <= 3000)
        #expect(batch.hasMore)
        try send(a, b, maxBytes: 3000)
        #expect(b.transactions.count == 8)
        #expect(throws: LifeStoreError.self) { try a.exportBatch(excluding: SyncInventory(), maxBytes: 256) }
        #expect(throws: LifeStoreError.self) { try a.exportBatch(excluding: SyncInventory(protocolVersion: 2)) }
    }
    @Test func v4MigrationCreatesRealBackupIncludingWALAndSeedsSessionsOnlyOnce() throws {
        let path = url()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try DatabaseQueue(path: path.path)
        try original.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;") }
        let id = UUID()
        try original.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1-immutable-revisions'),('v2-local-location-evidence'),('v3-revision-provenance'),('v4-local-timer-sessions');
                CREATE TABLE recordRevisions (id TEXT PRIMARY KEY NOT NULL,entityID TEXT NOT NULL,entityType TEXT NOT NULL,payload TEXT NOT NULL,parentIDsJSON TEXT NOT NULL,createdAt REAL NOT NULL,isDeleted INTEGER NOT NULL,origin TEXT NOT NULL) STRICT;
                CREATE TABLE locationEvidence (fingerprint TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL,importedAt REAL NOT NULL) STRICT;
                CREATE TABLE timerSessions (id TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,category TEXT NOT NULL,startTimestamp REAL NOT NULL) STRICT;
                """)
            try db.execute(sql: "INSERT INTO timerSessions VALUES (?, '迁移计时', '工作', ?)", arguments: [id.uuidString, start.timeIntervalSince1970])
            try db.execute(sql: "INSERT INTO locationEvidence VALUES ('local', 'WAL-only-evidence', 1)")
        }
        #expect(FileManager.default.fileExists(atPath: path.path + "-wal"))
        let migrated = try LifeStore(databaseURL: path)
        #expect(migrated.runningTimers.first?.id == id && migrated.runningTimers.first?.start == start)
        #expect(try migrated.inventory().timerRevisionIDs.count == 1)
        let backups = try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("pre-v5-") && $0.pathExtension == "sqlite" }
        #expect(backups.count == 1)
        let backup = try DatabaseQueue(path: try #require(backups.first).path)
        #expect(try backup.read { try String.fetchOne($0, sql: "SELECT payload FROM locationEvidence") } == "WAL-only-evidence")
        #expect(try backup.read { try String.fetchOne($0, sql: "SELECT id FROM timerSessions") } == id.uuidString)
        #expect(try backup.read { try $0.tableExists("timerRevisions") } == false)
        let reopened = try LifeStore(databaseURL: path)
        #expect(try reopened.inventory() == migrated.inventory())
        let after = try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("pre-v5-") && $0.pathExtension == "sqlite" }
        #expect(after.count == 1)
    }

    @Test func databaseFailureAfterFirstInsertRollsBackEntireBatch() throws {
        let source = try store(), target = try store()
        for name in ["第一条", "第二条"] { try source.save(LifeCore.Transaction(amountCents: 100, kind: .expense, category: "餐饮", merchant: name)) }
        let batch = try source.exportBatch(excluding: target.inventory())
        let rejected = try #require(batch.recordRevisions.last)
        try target.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_second_sync_row BEFORE INSERT ON recordRevisions WHEN lower(NEW.id) = lower('\(rejected.id.uuidString)') BEGIN SELECT RAISE(ABORT, 'simulated disk write failure'); END")
        }
        #expect(throws: (any Error).self) { try target.importBatch(batch) }
        #expect(try target.inventory().recordRevisionIDs.isEmpty)
        #expect(target.transactions.isEmpty && target.changeGeneration == 0)
        try target.database.write { db in try db.execute(sql: "DROP TRIGGER fail_second_sync_row") }
        try target.importBatch(batch)
        #expect(target.transactions.count == 2)
    }
    @Test func corruptTimerAndInvalidDatesStayOpaqueAndNeverReachStatistics() throws {
        let a = try store(), b = try store()
        var block = TimeBlock(title: "坏时间", category: "工作", start: start, end: start.addingTimeInterval(60))
        block.end = Date(timeIntervalSince1970: 1e100)
        let brokenTimer = SyncTimerRevision(id: UUID(), timerID: UUID(), payload: "{broken lifecycle", parentIDs: [], createdAt: start.timeIntervalSince1970)
        let brokenRecord = SyncRecordRevision(id: UUID(), entityID: block.id, entityType: "timeBlock", payload: try LifeStore.encode(block), parentIDs: [], createdAt: start.timeIntervalSince1970, isDeleted: false)
        try a.importBatch(SyncBatch(recordRevisions: [brokenRecord], timerRevisions: [brokenTimer]))
        #expect(a.timeBlocks.isEmpty && a.runningTimers.isEmpty && a.recordReadIssues.count == 2)
        try send(a, b)
        #expect(b.timeBlocks.isEmpty && b.runningTimers.isEmpty && b.recordReadIssues.count == 2)
        #expect(b.errorMessage != nil)
        let exported = try b.exportBatch(excluding: SyncInventory())
        #expect(exported.timerRevisions.first?.payload == brokenTimer.payload)
        #expect(exported.recordRevisions.first?.payload == brokenRecord.payload)
    }
    @Test func localWatchRetriesAndRefreshDoNotAnnounceFalseChanges() throws {
        let a = try store()
        let timer = try a.startTimer(title: "重试", category: "工作", at: start)
        let afterStart = a.changeGeneration
        try a.startTimer(title: "重试", category: "工作", at: start.addingTimeInterval(30), id: timer.id)
        try a.refresh()
        #expect(a.changeGeneration == afterStart)
        try a.finishTimer(id: timer.id, at: start.addingTimeInterval(60))
        let afterFinish = a.changeGeneration
        try a.finishTimer(id: timer.id, at: start.addingTimeInterval(90))
        try a.cancelTimer(id: timer.id)
        try a.refresh()
        #expect(a.changeGeneration == afterFinish)
    }
}
