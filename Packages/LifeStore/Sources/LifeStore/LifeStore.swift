import Foundation
import Observation
import CryptoKit
import SQLiteData
import GRDB
import LifeCore
#if os(macOS)
import Security
#endif

public struct ScreenSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var category: String
    public var start: Date
    public var end: Date
    public var summary: String
    public var deviceID: String
    public init(id: String, title: String, category: String, start: Date, end: Date, summary: String, deviceID: String = "local-mac") {
        self.id = id; self.title = title; self.category = category; self.start = start; self.end = end; self.summary = summary; self.deviceID = deviceID
    }
}
public struct RevisionChoice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let payload: String
    public let isDeleted: Bool
}
public struct RecordConflict: Identifiable, Equatable, Sendable {
    public var id: UUID { entityID }
    public let entityID: UUID
    public let kind: String
    public let versions: [RevisionChoice]
}
public enum LifeStoreError: LocalizedError {
    case invalidRecord(String), unresolvedConflict, missingRevision, staleEdit
    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let detail): return detail
        case .unresolvedConflict: return "这条记录有不同版本，请先选择保留的版本。"
        case .missingRevision: return "找不到所选版本，请刷新后重试。"
        case .staleEdit: return "这条记录已被其他操作修改或删除。请关闭后重新打开，避免覆盖较新的内容。"
        }
    }
}

// Every row is an immutable, complete logical revision. CloudKit's field merging never mixes
// the amount from one device with the transaction kind from another device.
@Table("recordRevisions")
struct RecordRevision: Sendable, Equatable {
    let id: UUID
    var entityID: String
    var entityType: String
    var payload: String
    var parentIDsJSON: String
    var createdAt: Double
    var isDeleted: Bool
    var origin: String
    var parents: [UUID] { (try? JSONDecoder().decode([UUID].self, from: Data(parentIDsJSON.utf8))) ?? [] }
}

private final class LocalCommitObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
private let localCommitNotification = Notification.Name("local.liferecord.storeCommitted")

public struct RecordReadIssue: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let entityID: String
    public let message: String
}

@MainActor @Observable
public final class LifeStore {
    public private(set) var transactions: [LifeCore.Transaction] = []
    public internal(set) var timeBlocks: [TimeBlock] = []
    public internal(set) var runningTimers: [RunningTimer] = []
    public internal(set) var recordReadIssues: [RecordReadIssue] = []
    public internal(set) var conflicts: [RecordConflict] = []
    public private(set) var syncStatus = "仅本机 · iCloud 尚未配置"
    public var errorMessage: String?
    public private(set) var changeGeneration: UInt64 = 0
    public static let didChangeNotification = Notification.Name("local.liferecord.syncContentChanged")
    @ObservationIgnored private var observedContent: Set<UUID>?
    @ObservationIgnored private let commitObserver = LocalCommitObserver()
    @ObservationIgnored private let databasePath: String
    @ObservationIgnored let database: DatabaseQueue
    @ObservationIgnored private var observation: (any DatabaseCancellable)?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored private var revisions: [RecordRevision] = []
    @ObservationIgnored private let cloudIdentifier: String?

    public init(databaseURL: URL? = nil, cloudContainerIdentifier: String? = nil) throws {
        let url: URL
        if let databaseURL { url = databaseURL } else {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LifeRecord", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("LifeRecord.sqlite")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        databasePath = url.standardizedFileURL.path
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        cloudIdentifier = cloudContainerIdentifier
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-immutable-revisions") { db in
            try db.execute(sql: """
                CREATE TABLE recordRevisions (
                  id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                  entityID TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
                  entityType TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
                  payload TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
                  parentIDsJSON TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
                  createdAt REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
                  isDeleted INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
                ) STRICT;
                CREATE INDEX revisionEntity ON recordRevisions(entityID);
                """)
        }
        migrator.registerMigration("v2-local-location-evidence") { db in
            try db.execute(sql: """
                CREATE TABLE locationEvidence (
                  fingerprint TEXT PRIMARY KEY NOT NULL,
                  payload TEXT NOT NULL,
                  importedAt REAL NOT NULL
                ) STRICT;
                """)
        }
        migrator.registerMigration("v3-revision-provenance") { db in
            try db.execute(sql: "ALTER TABLE recordRevisions ADD COLUMN origin TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'manual'")
        }
        migrator.registerMigration("v4-local-timer-sessions") { db in
            try db.execute(sql: """
                CREATE TABLE timerSessions (
                  id TEXT PRIMARY KEY NOT NULL,
                  title TEXT NOT NULL,
                  category TEXT NOT NULL,
                  startTimestamp REAL NOT NULL
                ) STRICT;
                """)
        }
        // SQLite's online backup includes committed WAL contents. Never copy just the .sqlite file.
        let needsBackup = try database.read { db in
            try db.tableExists("grdb_migrations") && String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v5-nearby-timer-revisions'") == nil
        }
        if needsBackup {
            let backupURL = url.deletingPathExtension().appendingPathExtension("pre-v5-\(UUID().uuidString).sqlite")
            let destination = try DatabaseQueue(path: backupURL.path)
            try database.backup(to: destination)
            guard try destination.read({ try String.fetchOne($0, sql: "PRAGMA quick_check") }) == "ok" else {
                throw LifeStoreError.invalidRecord("迁移前数据库备份未通过检查，原数据库尚未迁移。")
            }
            try destination.close()
        }
        migrator.registerMigration("v5-nearby-timer-revisions") { db in
            try db.execute(sql: """
                CREATE TABLE timerRevisions (
                  id TEXT PRIMARY KEY NOT NULL,
                  timerID TEXT NOT NULL,
                  payload TEXT NOT NULL,
                  parentIDsJSON TEXT NOT NULL,
                  createdAt REAL NOT NULL
                ) STRICT;
                CREATE INDEX timerRevisionEntity ON timerRevisions(timerID);
                """)
            for session in try TimerSessionRecord.fetchAll(db) {
                try Self.insertTimerRevision(db, payload: TimerRevisionPayload(timer: session.timer, state: .running), parents: [])
            }
        }
        try migrator.migrate(database)
        try refresh()
        observation = ValueObservation.tracking { db in
            (try RecordRevision.fetchAll(db), try TimerRevision.fetchAll(db))
        }
            .start(in: database, onError: { [weak self] error in
                Task { @MainActor in self?.errorMessage = error.localizedDescription }
            }, onChange: { [weak self] _ in
                Task { @MainActor in
                    do { try self?.refresh() } catch { self?.errorMessage = error.localizedDescription }
                }
            })
        let observedPath = databasePath
        commitObserver.token = NotificationCenter.default.addObserver(forName: localCommitNotification, object: nil, queue: nil) { [weak self] note in
            guard note.object as? String == observedPath else { return }
            Task { @MainActor [weak self] in
                do { try self?.refresh() } catch { self?.errorMessage = error.localizedDescription }
            }
        }
        if cloudContainerIdentifier != nil {
            syncStatus = Self.hasCloudEntitlement(cloudContainerIdentifier!) ? "iCloud 已配置 · 等待同步" : "仅本机 · 缺少有效 iCloud 签名配置"
        }
    }

    public func refresh() throws {
        let snapshot = try database.read { db in
            (try RecordRevision.fetchAll(db), try TimerRevision.fetchAll(db))
        }
        try apply(snapshot.0)
        applyTimerRevisions(snapshot.1, records: snapshot.0)
        if let warning = recordReadWarning { errorMessage = warning }
        let content = Set(snapshot.0.map(\.id) + snapshot.1.map(\.id))
        let changed = observedContent.map { $0 != content } ?? false
        observedContent = content
        if changed {
            changeGeneration &+= 1
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    func refreshAndNotify() throws {
        let before = changeGeneration
        try refresh()
        if changeGeneration != before { NotificationCenter.default.post(name: localCommitNotification, object: databasePath) }
    }

    private func apply(_ rows: [RecordRevision]) throws {
        var money: [LifeCore.Transaction] = [], blocks: [TimeBlock] = [], issues: [RecordConflict] = []
        var readIssues: [RecordReadIssue] = []
        for (entity, versions) in Dictionary(grouping: rows, by: \.entityID) {
            guard let entityID = UUID(uuidString: entity) else {
                readIssues += versions.map { RecordReadIssue(id: $0.id, entityID: entity, message: "记录标识无法解读，原始数据已保留。") }
                continue
            }
            let tips = Self.tips(versions)
            if tips.count > 1 {
                issues.append(RecordConflict(entityID: entityID, kind: tips[0].entityType, versions: tips.map {
                    RevisionChoice(id: $0.id, label: Self.label($0), payload: $0.payload, isDeleted: $0.isDeleted)
                }))
            } else if let revision = tips.first, !revision.isDeleted {
                do {
                    if revision.entityType == "transaction" {
                        let item = try JSONDecoder().decode(LifeCore.Transaction.self, from: Data(revision.payload.utf8))
                        guard item.id == entityID, item.amountCents > 0, item.amountCents <= 1_000_000_000_000, Self.validDate(item.date) else { throw LifeStoreError.invalidRecord("收支记录内容与版本不一致。") }
                        money.append(item)
                    } else if revision.entityType == "timeBlock" {
                        let item = try JSONDecoder().decode(TimeBlock.self, from: Data(revision.payload.utf8))
                        guard item.id == entityID, Self.validDate(item.start), Self.validDate(item.end), item.end > item.start else { throw LifeStoreError.invalidRecord("时间记录内容与版本不一致。") }
                        blocks.append(item)
                    } else { throw LifeStoreError.invalidRecord("未知记录类型。") }
                } catch {
                    readIssues.append(RecordReadIssue(id: revision.id, entityID: entity, message: "这条记录无法解读，已隔离显示；原始数据已保留。"))
                }
            }
        }
        let previousReadWarning = recordReadWarning
        recordReadIssues = readIssues.sorted { $0.id.uuidString < $1.id.uuidString }
        if let warning = recordReadWarning { errorMessage = warning }
        else if errorMessage == previousReadWarning { errorMessage = nil }
        revisions = rows
        transactions = money.sorted { $0.date > $1.date }
        timeBlocks = blocks.sorted { $0.start > $1.start }
        conflicts = issues.sorted { $0.entityID.uuidString < $1.entityID.uuidString }
    }

    var recordReadWarning: String? {
        guard !recordReadIssues.isEmpty else { return nil }
        let ids = recordReadIssues.prefix(3).map { String($0.id.uuidString.prefix(8)) }.joined(separator: "、")
        return "有 \(recordReadIssues.count) 条记录无法解读，已隔离（版本 \(ids)）。其他记录仍可使用，原始数据库未删除；请保留备份后检查。"
    }

    nonisolated static func tips(_ rows: [RecordRevision]) -> [RecordRevision] {
        let parents = Set(rows.flatMap(\.parents))
        return rows.filter { !parents.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    nonisolated private static func label(_ row: RecordRevision) -> String {
        if row.isDeleted { return "删除此记录" }
        if row.entityType == "transaction", let value = try? JSONDecoder().decode(LifeCore.Transaction.self, from: Data(row.payload.utf8)) {
            return "\(value.merchant) · \(Money.format(value.amountCents)) · \(value.kind.rawValue)"
        }
        if let value = try? JSONDecoder().decode(TimeBlock.self, from: Data(row.payload.utf8)) { return "\(value.title) · \(value.start.formatted())" }
        return "无法解读的版本"
    }
    public func save(_ transaction: LifeCore.Transaction) throws {
        guard transaction.amountCents > 0, transaction.amountCents <= 1_000_000_000_000, Self.validDate(transaction.date) else { throw LifeStoreError.invalidRecord("金额需大于零且不超过100亿元，日期需有效。") }
        try append(entityID: transaction.id, kind: "transaction", payload: Self.encode(transaction))
    }
    public func save(_ block: TimeBlock) throws {
        guard Self.validDate(block.start), Self.validDate(block.end), block.end > block.start else { throw LifeStoreError.invalidRecord("结束时间必须晚于开始时间，且日期需有效。") }
        try append(entityID: block.id, kind: "timeBlock", payload: Self.encode(block))
    }
    public func deleteTransaction(id: UUID) throws { try append(entityID: id, kind: "transaction", payload: "", deleted: true) }
    public func deleteTimeBlock(id: UUID) throws { try append(entityID: id, kind: "timeBlock", payload: "", deleted: true) }

    public func save(_ transaction: LifeCore.Transaction, ifUnchangedFrom base: LifeCore.Transaction?) throws {
        guard transaction.amountCents > 0, transaction.amountCents <= 1_000_000_000_000, Self.validDate(transaction.date) else { throw LifeStoreError.invalidRecord("金额需大于零且不超过100亿元，日期需有效。") }
        try append(entityID: transaction.id, kind: "transaction", payload: Self.encode(transaction), expectedPayload: try base.map(Self.encode), enforceExpected: true)
    }
    public func save(_ block: TimeBlock, ifUnchangedFrom base: TimeBlock?) throws {
        guard Self.validDate(block.start), Self.validDate(block.end), block.end > block.start else { throw LifeStoreError.invalidRecord("结束时间必须晚于开始时间，且日期需有效。") }
        try append(entityID: block.id, kind: "timeBlock", payload: Self.encode(block), expectedPayload: try base.map(Self.encode), enforceExpected: true)
    }
    public func deleteTransaction(id: UUID, ifUnchangedFrom base: LifeCore.Transaction) throws {
        try append(entityID: id, kind: "transaction", payload: "", deleted: true, expectedPayload: Self.encode(base), enforceExpected: true)
    }
    public func deleteTimeBlock(id: UUID, ifUnchangedFrom base: TimeBlock) throws {
        try append(entityID: id, kind: "timeBlock", payload: "", deleted: true, expectedPayload: Self.encode(base), enforceExpected: true)
    }
    private func append(entityID: UUID, kind: String, payload: String, deleted: Bool = false, expectedPayload: String? = nil, enforceExpected: Bool = false) throws {
        // Read current parents inside the same SQLite write transaction, so another window's edit
        // cannot be overwritten using stale in-memory parents.
        try database.write { db in
            try Self.requireUnconflictedTimer(db, id: entityID)
            let rows = try RecordRevision.fetchAll(db).filter { $0.entityID == entityID.uuidString }
            let tips = Self.tips(rows)
            guard tips.count <= 1 else { throw LifeStoreError.unresolvedConflict }
            if enforceExpected {
                if let expectedPayload {
                    guard let current = tips.first, !current.isDeleted, current.payload == expectedPayload else { throw LifeStoreError.staleEdit }
                } else { guard tips.isEmpty else { throw LifeStoreError.staleEdit } }
            }
            if kind == "timeBlock", !deleted {
                let proposed = try JSONDecoder().decode(TimeBlock.self, from: Data(payload.utf8))
                if !Self.validInterval(proposed.start, proposed.end) {
                    // Only an existing completed timer may retain a long interval. Compare inside
                    // this write transaction so stale callers cannot expand a newer shortened range.
                    guard let current = tips.first, !current.isDeleted, current.entityType == "timeBlock",
                          let existing = try? JSONDecoder().decode(TimeBlock.self, from: Data(current.payload.utf8)),
                          existing.source == .manual, existing.evidence == "手动开始并结束的计时。",
                          proposed.start >= existing.start, proposed.end <= existing.end else {
                        throw LifeStoreError.invalidRecord("新建手动事项不能超过7天；已有长计时只允许保留或缩短原时间范围。")
                    }
                }
            }
            if let last = tips.first, last.payload == payload, last.isDeleted == deleted { return }
            try Self.insert(db, entityID: entityID, kind: kind, payload: payload, deleted: deleted, parents: tips.map(\.id))
        }
        try refreshAndNotify()
    }
    nonisolated static func insert(_ db: Database, entityID: UUID, kind: String, payload: String, deleted: Bool, parents: [UUID], origin: String = "manual") throws {
        try insertRevision(db, entityID: entityID, kind: kind, payload: payload, deleted: deleted, parents: parents, origin: origin)
    }
    @discardableResult nonisolated static func insertRevision(_ db: Database, entityID: UUID, kind: String, payload: String, deleted: Bool, parents: [UUID], origin: String = "manual") throws -> UUID {
        let revision = RecordRevision(id: UUID(), entityID: entityID.uuidString, entityType: kind, payload: payload, parentIDsJSON: try encode(parents), createdAt: Date().timeIntervalSince1970, isDeleted: deleted, origin: origin)
        try RecordRevision.insert { revision }.execute(db)
        return revision.id
    }
    public func resolveConflict(entityID: UUID, choosing revisionID: UUID) throws {
        try database.write { db in
            if try Self.resolveTimerConflict(db, entityID: entityID, choosing: revisionID) { return }
            let rows = try RecordRevision.fetchAll(db).filter { $0.entityID == entityID.uuidString }
            let tips = Self.tips(rows)
            guard tips.count > 1, let chosen = tips.first(where: { $0.id == revisionID }) else { throw LifeStoreError.missingRevision }
            try Self.insert(db, entityID: entityID, kind: chosen.entityType, payload: chosen.payload, deleted: chosen.isDeleted, parents: tips.map(\.id))
        }
        try refreshAndNotify()
    }
    nonisolated static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    nonisolated static func stableID(_ input: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    nonisolated static func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && (946684800...4102444800).contains(value.timeIntervalSince1970)
    }
    nonisolated static func validInterval(_ start: Date, _ end: Date) -> Bool { validDate(start) && validDate(end) && end > start && end.timeIntervalSince(start) <= 7 * 86400 }

    public func requestSync() async {
        guard let identifier = cloudIdentifier else { syncStatus = "仅本机 · iCloud 尚未配置"; return }
        guard Self.hasCloudEntitlement(identifier) else { syncStatus = "仅本机 · 缺少有效 iCloud 签名配置"; return }
        syncStatus = "正在同步 iCloud…"
        do {
            if syncEngine == nil { syncEngine = try SyncEngine(for: database, privateTables: RecordRevision.self, containerIdentifier: identifier, startImmediately: false) }
            try await syncEngine?.start()
            try await syncEngine?.syncChanges()
            try refresh()
            syncStatus = "iCloud 同步请求已完成 · \(Date().formatted(date: .omitted, time: .shortened))"
            errorMessage = recordReadWarning
        } catch {
            syncStatus = "iCloud 同步失败 · 本机记录仍可使用"
            errorMessage = error.localizedDescription
        }
    }
    nonisolated private static func hasCloudEntitlement(_ identifier: String) -> Bool {
        guard identifier.hasPrefix("iCloud.") else { return false }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
        else { return false }
        return containers.contains(identifier) && services.contains("CloudKit")
        #else
        // Development iOS installations carry a signed provisioning profile. Refuse to invoke
        // CloudKit when its entitlement cannot be established, avoiding missing-entitlement crashes.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
              let begin = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = String(text[begin.lowerBound..<end.upperBound]).data(using: .utf8),
              let profile = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String]
        else { return false }
        return containers.contains(identifier) && services.contains("CloudKit")
        #endif
    }
}

extension LifeStore {
    public func importScreenSummaries(_ summaries: [ScreenSummary]) throws {
        try importScreens(summaries, window: nil)
    }

    /// A successful, complete source query may reconcile its exact window. Failed queries must
    /// throw before calling this overload; an empty successful snapshot is an actual deletion.
    public func importScreenSummaries(_ summaries: [ScreenSummary], windowStart: Date, windowEnd: Date, deviceID: String) throws {
        guard Self.validDate(windowStart), Self.validDate(windowEnd), windowEnd > windowStart,
              summaries.allSatisfy({ $0.deviceID == deviceID && $0.start >= windowStart && $0.end <= windowEnd })
        else { throw LifeStoreError.invalidRecord("屏幕摘要快照超出查询范围。") }
        try importScreens(summaries, window: (windowStart, windowEnd, deviceID))
    }
    private func importScreens(_ summaries: [ScreenSummary], window: (Date, Date, String)?) throws {
        guard summaries.allSatisfy({ Self.validInterval($0.start, $0.end) }) else { throw LifeStoreError.invalidRecord("屏幕摘要含无效时间，未导入。") }
        try database.write { db in
            var all = try RecordRevision.fetchAll(db)
            let ids = Set(summaries.map { Self.screenID($0) })
            if let (start, end, device) = window {
                for rows in Dictionary(grouping: all, by: \.entityID).values {
                    let tips = Self.tips(rows)
                    guard tips.count == 1, let tip = tips.first, !tip.isDeleted,
                          tip.origin == "screen|" + device,
                          !rows.contains(where: { $0.origin == "manual" }),
                          let id = UUID(uuidString: tip.entityID), !ids.contains(id),
                          let block = try? JSONDecoder().decode(TimeBlock.self, from: Data(tip.payload.utf8)),
                          block.start >= start, block.end <= end else { continue }
                    try Self.insert(db, entityID: id, kind: "timeBlock", payload: "", deleted: true, parents: [tip.id], origin: "screen|" + device)
                }
                all = try RecordRevision.fetchAll(db)
            }
            for summary in summaries {
                let id = Self.screenID(summary), origin = "screen|" + summary.deviceID
                let rows = all.filter { $0.entityID == id.uuidString }, tips = Self.tips(rows)
                // Any manual revision (including deletion) remains authoritative across imports.
                guard !rows.contains(where: { $0.origin == "manual" }), tips.count <= 1 else { continue }
                if window == nil && !rows.isEmpty { continue }
                let activeBlocks = Dictionary(grouping: all, by: \.entityID).values.flatMap { Self.tips($0) }.filter { !$0.isDeleted && $0.entityType == "timeBlock" && $0.entityID != id.uuidString }.compactMap { try? JSONDecoder().decode(TimeBlock.self, from: Data($0.payload.utf8)) }.filter { $0.source == .screen }
                // Historical payloads also protect a manually deleted card if the source later
                // shifts its interval or AI identifier. Source reconciliation cannot resurrect it.
                let protectedBlocks = Dictionary(grouping: all, by: \.entityID).values.filter { $0.contains(where: { $0.origin == "manual" }) }.flatMap { $0 }.compactMap { try? JSONDecoder().decode(TimeBlock.self, from: Data($0.payload.utf8)) }.filter { $0.source == .screen }
                guard !(activeBlocks + protectedBlocks).contains(where: { $0.id != id && $0.start < summary.end && $0.end > summary.start }) else { continue }
                let block = TimeBlock(id: id, title: summary.title, category: summary.category, start: summary.start, end: summary.end, note: summary.summary, source: .screen, status: .pending, evidence: "屏幕摘要草稿；请核实内容和时间。")
                let payload = try Self.encode(block)
                if let tip = tips.first, !tip.isDeleted, tip.payload == payload { continue }
                try Self.insert(db, entityID: id, kind: "timeBlock", payload: payload, deleted: false, parents: tips.map(\.id), origin: origin)
                all = try RecordRevision.fetchAll(db)
            }
        }
        try refreshAndNotify()
    }
    nonisolated private static func screenID(_ summary: ScreenSummary) -> UUID {
        stableID("screen|\(summary.deviceID)|\(summary.start.timeIntervalSince1970)|\(summary.end.timeIntervalSince1970)")
    }

    public func importLocationFeatures(_ data: Data, defaults: UserDefaults = .standard) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        let root = json as? [String: Any]
        let features = root?["features"] as? [[String: Any]] ?? root?["locations"] as? [[String: Any]] ?? json as? [[String: Any]] ?? []
        guard !features.isEmpty else { throw LifeStoreError.invalidRecord("文件没有 Overland features 或 locations 数组。") }
        var blocks: [TimeBlock] = []
        let places = PlaceBook.load(defaults)
        for feature in features {
            let properties = feature["properties"] as? [String: Any] ?? feature
            guard let arrival = Self.locationDate(properties["arrival_date"] ?? properties["arrivalDate"]),
                  let departure = Self.locationDate(properties["departure_date"] ?? properties["departureDate"]),
                  Self.validInterval(arrival, departure) else { continue }
            // CLLocation's distantPast/distantFuture sentinels and unfinished visits never become
            // multi-year blocks. Coordinates alone cannot establish what a person was doing.
            let id = Self.visitID(properties: properties, arrival: arrival, departure: departure)
            let place = Self.coordinate(of: feature).flatMap { PlaceBook.match($0, in: places) }
            blocks.append(TimeBlock(id: id, title: "定位停留（待确认）", category: "未分类", start: arrival, end: departure, note: "定位只证明停留，不能判断当时做了什么。", source: .location, status: .pending, evidence: "系统识别到的一次到访；坐标只保存在这台手机上。", place: place?.name))
        }
        // Persist all raw evidence locally before the capture adapter acknowledges its queue.
        // This table is deliberately excluded from SyncEngine's table list.
        let rawPayloads = try features.map { feature in
            String(decoding: try JSONSerialization.data(withJSONObject: feature, options: [.sortedKeys]), as: UTF8.self)
        }
        try database.write { db in
            for payload in rawPayloads {
                let fingerprint = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
                try db.execute(sql: "INSERT OR IGNORE INTO locationEvidence (fingerprint, payload, importedAt) VALUES (?, ?, ?)", arguments: [fingerprint, payload, Date().timeIntervalSince1970])
            }
            var ids = Set(try RecordRevision.fetchAll(db).map(\.entityID))
            for block in blocks where !ids.contains(block.id.uuidString) {
                try Self.insert(db, entityID: block.id, kind: "timeBlock", payload: Self.encode(block), deleted: false, parents: [], origin: "location")
                ids.insert(block.id.uuidString)
            }
        }
        try refreshAndNotify()
    }
    nonisolated static func visitID(properties: [String: Any], arrival: Date, departure: Date) -> UUID {
        stableID("visit|" + (properties["device_id"] as? String ?? "overland") + "|\(arrival.timeIntervalSince1970)|\(departure.timeIntervalSince1970)")
    }
    nonisolated static func coordinate(of feature: [String: Any]) -> (latitude: Double, longitude: Double)? {
        guard let geometry = feature["geometry"] as? [String: Any], let pair = geometry["coordinates"] as? [Double], pair.count >= 2,
              (-90...90).contains(pair[1]), (-180...180).contains(pair[0]) else { return nil }
        return (pair[1], pair[0])
    }
    nonisolated static func locationDate(_ value: Any?) -> Date? {
        if let number = value as? Double {
            let date = Date(timeIntervalSince1970: number)
            return validDate(date) ? date : nil
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return validDate(date) ? date : nil }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string).flatMap { validDate($0) ? $0 : nil }
    }
}
