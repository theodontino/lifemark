import Foundation
import GRDB
import SQLiteData

public struct SyncInventory: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var recordRevisionIDs: [UUID]
    public var timerRevisionIDs: [UUID]
    public init(protocolVersion: Int = 1, recordRevisionIDs: [UUID] = [], timerRevisionIDs: [UUID] = []) {
        self.protocolVersion = protocolVersion; self.recordRevisionIDs = recordRevisionIDs; self.timerRevisionIDs = timerRevisionIDs
    }
}
public struct SyncRecordRevision: Codable, Sendable, Equatable {
    public var id: UUID
    public var entityID: UUID
    public var entityType: String
    public var payload: String
    public var parentIDs: [UUID]
    public var createdAt: Double
    public var isDeleted: Bool
    public var origin: String
    public init(id: UUID, entityID: UUID, entityType: String, payload: String, parentIDs: [UUID], createdAt: Double, isDeleted: Bool, origin: String = "manual") {
        self.id = id; self.entityID = entityID; self.entityType = entityType; self.payload = payload; self.parentIDs = parentIDs; self.createdAt = createdAt; self.isDeleted = isDeleted; self.origin = origin
    }
    init(_ row: RecordRevision) throws {
        guard let entityID = UUID(uuidString: row.entityID) else { throw LifeStoreError.invalidRecord("原始记录标识损坏，请保留数据库备份后检查。") }
        self.init(id: row.id, entityID: entityID, entityType: row.entityType, payload: row.payload, parentIDs: try JSONDecoder().decode([UUID].self, from: Data(row.parentIDsJSON.utf8)), createdAt: row.createdAt, isDeleted: row.isDeleted, origin: row.origin)
    }
    var row: RecordRevision { get throws { RecordRevision(id: id, entityID: entityID.uuidString, entityType: entityType, payload: payload, parentIDsJSON: try LifeStore.encode(parentIDs), createdAt: createdAt, isDeleted: isDeleted, origin: origin) } }
}
public struct SyncTimerRevision: Codable, Sendable, Equatable {
    public var id: UUID
    public var timerID: UUID
    public var payload: String
    public var parentIDs: [UUID]
    public var createdAt: Double
    public init(id: UUID, timerID: UUID, payload: String, parentIDs: [UUID], createdAt: Double) {
        self.id = id; self.timerID = timerID; self.payload = payload; self.parentIDs = parentIDs; self.createdAt = createdAt
    }
    init(_ row: TimerRevision) throws {
        guard let timerID = UUID(uuidString: row.timerID) else { throw LifeStoreError.invalidRecord("原始计时标识损坏，请保留数据库备份后检查。") }
        self.init(id: row.id, timerID: timerID, payload: row.payload, parentIDs: try JSONDecoder().decode([UUID].self, from: Data(row.parentIDsJSON.utf8)), createdAt: row.createdAt)
    }
    var row: TimerRevision { get throws { TimerRevision(id: id, timerID: timerID.uuidString, payload: payload, parentIDsJSON: try LifeStore.encode(parentIDs), createdAt: createdAt) } }
}
public struct SyncBatch: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var recordRevisions: [SyncRecordRevision]
    public var timerRevisions: [SyncTimerRevision]
    public var hasMore: Bool
    public init(protocolVersion: Int = 1, recordRevisions: [SyncRecordRevision] = [], timerRevisions: [SyncTimerRevision] = [], hasMore: Bool = false) {
        self.protocolVersion = protocolVersion; self.recordRevisions = recordRevisions; self.timerRevisions = timerRevisions; self.hasMore = hasMore
    }
    public var isEmpty: Bool { recordRevisions.isEmpty && timerRevisions.isEmpty }
}
public struct SyncImportResult: Codable, Sendable, Equatable {
    public let insertedRecordCount: Int
    public let insertedTimerCount: Int
    public let duplicateCount: Int
    public var hasChanges: Bool { insertedRecordCount + insertedTimerCount > 0 }
}

extension LifeStore {
    public func inventory() throws -> SyncInventory {
        try database.read { db in
            SyncInventory(recordRevisionIDs: try RecordRevision.fetchAll(db).map(\.id).sorted(by: Self.uuidOrder), timerRevisionIDs: try TimerRevision.fetchAll(db).map(\.id).sorted(by: Self.uuidOrder))
        }
    }
    /// Missing dependencies and a timer's associated ledger revision are indivisible.
    /// Recompute the receiver's inventory after each imported page before requesting the next one.
    public func exportBatch(excluding remote: SyncInventory, limit: Int = 256, maxBytes: Int = 4 * 1024 * 1024) throws -> SyncBatch {
        guard remote.protocolVersion == 1 else { throw Self.syncError("同步协议版本不受支持。") }
        guard (1...1024).contains(limit), (256...8 * 1024 * 1024).contains(maxBytes),
              Set(remote.recordRevisionIDs).count == remote.recordRevisionIDs.count,
              Set(remote.timerRevisionIDs).count == remote.timerRevisionIDs.count else { throw Self.syncError("同步清单或分片上限无效。") }
        return try database.read { db in
            let records = try RecordRevision.fetchAll(db).map(SyncRecordRevision.init)
            let timers = try TimerRevision.fetchAll(db).map(SyncTimerRevision.init)
            try Self.validateGraph(records: records, timers: timers)
            let byRecord = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            let byTimer = Dictionary(uniqueKeysWithValues: timers.map { ($0.id, $0) })
            let known = Set(remote.recordRevisionIDs + remote.timerRevisionIDs)
            let allIDs = Set(byRecord.keys).union(byTimer.keys)
            var dependencies: [UUID: Set<UUID>] = [:]
            for record in records { dependencies[record.id] = Set(record.parentIDs) }
            for timer in timers {
                dependencies[timer.id] = Set(timer.parentIDs)
                if let value = try? JSONDecoder().decode(TimerRevisionPayload.self, from: Data(timer.payload.utf8)), let record = value.recordRevisionID {
                    dependencies[timer.id, default: []].insert(record)
                    // Reverse edge makes the paired ledger+timer terminal state atomic on the wire.
                    dependencies[record, default: []].insert(timer.id)
                }
            }
            var selected = Set<UUID>()
            func makeBatch(_ ids: Set<UUID>) -> SyncBatch {
                SyncBatch(recordRevisions: records.filter { ids.contains($0.id) }.sorted { Self.uuidOrder($0.id, $1.id) }, timerRevisions: timers.filter { ids.contains($0.id) }.sorted { Self.uuidOrder($0.id, $1.id) }, hasMore: !allIDs.subtracting(known).subtracting(ids).isEmpty)
            }
            for id in allIDs.subtracting(known).sorted(by: Self.uuidOrder) where !selected.contains(id) {
                var group = Set<UUID>(), pending = [id]
                while let dependency = pending.popLast() {
                    if known.contains(dependency) || selected.contains(dependency) || !group.insert(dependency).inserted { continue }
                    pending += dependencies[dependency, default: []]
                }
                let candidate = selected.union(group)
                let candidateBytes = try Self.encodedSize(makeBatch(candidate))
                if candidate.count > limit || candidateBytes > maxBytes {
                    // Skip this entire closure; a later smaller independent group can still fit.
                    continue
                }
                selected = candidate
            }
            guard !selected.isEmpty || allIDs.subtracting(known).isEmpty else { throw Self.syncError("单条记录及其必需历史超过本批大小限制，请提高上限或检查该记录。") }
            return makeBatch(selected)
        }
    }
    /// Envelope/graph/UUID errors roll back the whole batch. Opaque damaged payloads are retained
    /// byte-for-byte and quarantined by refresh(), preserving healthy independent records.
    @discardableResult
    public func importBatch(_ batch: SyncBatch) throws -> SyncImportResult {
        guard batch.protocolVersion == 1 else { throw Self.syncError("同步协议版本不受支持。") }
        guard batch.recordRevisions.count + batch.timerRevisions.count <= 1024,
              try Self.encodedSize(batch) <= 8 * 1024 * 1024 else { throw Self.syncError("同步批次超过允许大小。") }
        let result = try database.write { db in
            let storedRecords = try RecordRevision.fetchAll(db).map(SyncRecordRevision.init)
            let storedTimers = try TimerRevision.fetchAll(db).map(SyncTimerRevision.init)
            var records = Dictionary(uniqueKeysWithValues: storedRecords.map { ($0.id, $0) })
            var timers = Dictionary(uniqueKeysWithValues: storedTimers.map { ($0.id, $0) })
            var duplicates = 0, newRecords: [SyncRecordRevision] = [], newTimers: [SyncTimerRevision] = []
            var incoming = Set<UUID>()
            for record in batch.recordRevisions {
                guard incoming.insert(record.id).inserted else { throw Self.syncError("同一批中版本标识重复。") }
                guard timers[record.id] == nil else { throw Self.syncError("版本标识已被另一类记录使用。") }
                if let old = records[record.id] {
                    guard old == record else { throw Self.syncError("相同版本标识的内容不同；没有覆盖原始记录。") }
                    duplicates += 1
                } else { records[record.id] = record; newRecords.append(record) }
            }
            for timer in batch.timerRevisions {
                guard incoming.insert(timer.id).inserted else { throw Self.syncError("同一批中版本标识重复。") }
                guard records[timer.id] == nil else { throw Self.syncError("版本标识已被另一类记录使用。") }
                if let old = timers[timer.id] {
                    guard old == timer else { throw Self.syncError("相同计时版本标识的内容不同；没有覆盖原始记录。") }
                    duplicates += 1
                } else { timers[timer.id] = timer; newTimers.append(timer) }
            }
            try Self.validateGraph(records: Array(records.values), timers: Array(timers.values))
            for value in newRecords { let row = try value.row; try RecordRevision.insert { row }.execute(db) }
            for value in newTimers { let row = try value.row; try TimerRevision.insert { row }.execute(db) }
            if !newRecords.isEmpty || !newTimers.isEmpty { try Self.rebuildTimerProjection(db) }
            return SyncImportResult(insertedRecordCount: newRecords.count, insertedTimerCount: newTimers.count, duplicateCount: duplicates)
        }
        if result.hasChanges { try refreshAndNotify() }
        return result
    }
    nonisolated private static func syncError(_ message: String) -> LifeStoreError { .invalidRecord(message) }
    nonisolated private static func uuidOrder(_ a: UUID, _ b: UUID) -> Bool { a.uuidString < b.uuidString }
    nonisolated private static func encodedSize(_ batch: SyncBatch) throws -> Int { try JSONEncoder().encode(batch).count }
    nonisolated private static func validateGraph(records: [SyncRecordRevision], timers: [SyncTimerRevision]) throws {
        let recordIDs = Set(records.map(\.id)), timerIDs = Set(timers.map(\.id))
        guard recordIDs.count == records.count, timerIDs.count == timers.count, recordIDs.isDisjoint(with: timerIDs) else { throw syncError("版本标识重复。") }
        let recordMap = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let timerMap = Dictionary(uniqueKeysWithValues: timers.map { ($0.id, $0) })
        var graph: [UUID: [UUID]] = [:]
        var entityKinds: [UUID: String] = [:]
        for value in records {
            guard ["transaction", "timeBlock"].contains(value.entityType), value.createdAt.isFinite,
                  value.parentIDs.count == Set(value.parentIDs).count, !value.parentIDs.contains(value.id) else { throw syncError("记录版本结构无效。") }
            if let kind = entityKinds[value.entityID], kind != value.entityType { throw syncError("同一记录混用了不同类型。") }
            entityKinds[value.entityID] = value.entityType
            for parentID in value.parentIDs {
                guard let parent = recordMap[parentID], parent.entityID == value.entityID, parent.entityType == value.entityType else { throw syncError("缺少父版本或父版本属于其他记录。") }
            }
            graph[value.id] = value.parentIDs
        }
        for value in timers {
            guard value.createdAt.isFinite, value.parentIDs.count == Set(value.parentIDs).count, !value.parentIDs.contains(value.id) else { throw syncError("计时版本结构无效。") }
            for parentID in value.parentIDs { guard timerMap[parentID]?.timerID == value.timerID else { throw syncError("计时父版本缺失或属于其他计时。") } }
            if let payload = try? JSONDecoder().decode(TimerRevisionPayload.self, from: Data(value.payload.utf8)) {
                guard payload.timer.id == value.timerID, validDate(payload.timer.start), !payload.timer.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw syncError("计时内容和版本标识不一致。") }
                if payload.state == .finished && payload.recordRevisionID == nil { throw syncError("完成的计时缺少对应时间记录。") }
                if let id = payload.recordRevisionID {
                    guard let record = recordMap[id], record.entityID == value.timerID, record.entityType == "timeBlock" else { throw syncError("计时缺少对应时间记录版本。") }
                    if payload.state != .finished && !record.isDeleted { throw syncError("未完成的计时不能保存完成时间。") }
                }
            }
            graph[value.id] = value.parentIDs
        }
        // Iterative Kahn traversal avoids recursion limits on long offline revision histories.
        var remaining = graph.mapValues(\.count), children: [UUID: [UUID]] = [:]
        for (id, parents) in graph { for parent in parents { children[parent, default: []].append(id) } }
        var ready = remaining.filter { $0.value == 0 }.map(\.key), visited = 0
        while let id = ready.popLast() {
            visited += 1
            for child in children[id, default: []] { remaining[child]! -= 1; if remaining[child] == 0 { ready.append(child) } }
        }
        guard visited == graph.count else { throw syncError("版本父链出现循环。") }
    }
}
