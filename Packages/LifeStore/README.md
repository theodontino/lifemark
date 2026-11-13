# LifeStore

原生 macOS / iOS 共用的本机 SQLite 存储与 iCloud 同步准备层。最低 iOS 17 / macOS 14，Swift 6.4；固定依赖 SQLiteData 1.13.0（MIT）。

每次编辑、删除、冲突选择均追加一个不可变完整版本。逻辑记录与版本各有 UUID；版本包含父版本列表。不同设备从同一父版本修改后形成分支，界面收到 `conflicts`，该逻辑记录暂时不在 `transactions` / `timeBlocks` 中，直到用户显式选版。因此跨设备不会悄悄混合金额、收支方向等字段。删除保留为版本，并不移除历史。

本机记录立即写入 SQLite，在关闭后仍保留。默认存放应用 Application Support/LifeRecord/LifeRecord.sqlite；测试可注入数据库 URL。`ValueObservation` 监听数据库变化，远程入库同样刷新界面。

只有 `recordRevisions` 作为 privateTables 交给 SQLiteData `SyncEngine`。原始定位特征保存在 **不参与同步** 的 `locationEvidence` 表；导入成功表示原始特征和可派生的草稿已经在同一事务提交，采集程序才能清理已提交队列。完成的有效停留仅生成待确认时间段；普通定位点、未完成停留和系统的极端日期只作为本机证据保留，不能推断任务。原始坐标不进入同步版本。

屏幕摘要默认生成待确认草稿。只按完整查询窗口调用 `importScreenSummaries(_:windowStart:windowEnd:deviceID:)` 时，才对该窗口做源快照核对；查询失败必须抛出错误，禁止用失败后的空数组假冒成功快照。手动修正、确认、删除和冲突保留。设备与起止时间生成稳定逻辑 ID，避免 AI 每次查询改变摘要 ID 后重复入库。普通 `importScreenSummaries(_:)` 保守追加，保留已导入或修改的记录。

未传入云容器标识时明确显示“仅本机 · iCloud 尚未配置”。即使传入标识，也必须通过当前应用签名的 iCloud 容器和 CloudKit 权限检查才会构造 SyncEngine；iOS 开发安装通过内嵌 provisioning profile 检查，macOS 读取当前进程签名权限。没有付费开发者资格、有效签名或真实双设备测试时，不应宣称云同步已经可用。当前代码已接入库的真实同步 API，但此交付只验证本机存储；iCloud 实际连通、后台通知与双设备同步尚未验证。iOS App Store 安装没有内嵌 profile 的情形目前保守保持本机模式，需要发布前补充该发行渠道的签名能力验证。

同步不依赖 Mac 常开：未来完成签名与云容器配置后，各设备直接与 Apple CloudKit 通信。`requestSync()` 可手动触发，已启动的 SyncEngine 负责自动同步。只有该调用真正返回时才显示“同步请求已完成”，不会把仅本机写入当作云端成功。

测试：`swift test --scratch-path /private/tmp/liferecord-store-build`。本机权限受限环境需将 Swift/Clang 模块缓存指向 `/private/tmp`。


## Nearby synchronization protocol 1

`LifeStore` is main-actor isolated. The synchronous throwing entry points are
`inventory()`, `exportBatch(excluding:limit:maxBytes:)`, and `importBatch(_:)`.
All `Sync*` transport values are `Codable`, `Sendable`, and `Equatable`.
Inventories contain sorted immutable revision UUIDs for records and timers.
Exchange an inventory, export missing revisions, atomically import the page,
then request another page using a fresh receiver inventory until `hasMore` is false.
A lost acknowledgment can safely resend the identical page. Existing UUIDs are
accepted only with identical content; a conflicting UUID never replaces data.

Pages default to 256 revisions and 4 MiB of complete `JSONEncoder` output.
The caller can choose 1–1024 revisions and 256 bytes–8 MiB. Import rejects more
than 1024 revisions or 8 MiB. Parent closure must already exist on the receiver
or travel in the same page. A timer revision and its referenced TimeBlock
revision form one indivisible missing-dependency group. Groups that do not fit
are deferred, while smaller independent groups can make progress; an empty
page with remaining oversized data throws an explicit error. Every page must
be imported before its updated inventory is used to export the next page.

Wire fields are stable for protocol 1: `SyncInventory` carries
`protocolVersion`, `recordRevisionIDs`, `timerRevisionIDs`; `SyncBatch` carries
`protocolVersion`, `recordRevisions`, `timerRevisions`, `hasMore`.
`SyncRecordRevision` preserves `id`, `entityID`, `entityType`, opaque `payload`,
`parentIDs`, `createdAt` (Unix seconds), `isDeleted`, and `origin`.
`SyncTimerRevision` preserves `id`, `timerID`, opaque `payload`, `parentIDs`,
and `createdAt` (Unix seconds). Payload JSON dates follow Foundation's default
JSON date encoding (seconds since the 2001 reference date). A timer payload
contains `timer`, `state` (`running`, `finished`, `cancelled`), and an optional
`recordRevisionID`; a finished timer must reference its TimeBlock revision.

Unknown protocol versions, malformed envelopes, UUID collisions, missing or
cross-entity parents, cycles, and incomplete timer references reject the whole
batch. Opaque damaged record payloads are stored unchanged and isolated by
`recordReadIssues`, allowing independent healthy records to remain available.
Only immutable logical revisions are exported: raw location evidence, images,
settings, credentials, and keys are outside the protocol.

`timerRevisions` is authoritative; `timerSessions` is a disposable running-timer
projection. Conflicting timer tips and their ledger tips produce a single
`RecordConflict(kind: "timer")`; running and completed projections are hidden
until `resolveConflict(entityID:choosing:)` atomically joins both chains.
Different timer IDs and both successors of offline switches remain independent.
`LifeStore.didChangeNotification` and observable `changeGeneration` change only
when the immutable revision set changes, including commits seen through another
connection. Idempotent retransmission and watch retries do not increment it.

Before migrating an existing store to v5, GRDB's online SQLite backup creates a
sibling `*.pre-v5-<UUID>.sqlite`, validates it with `PRAGMA quick_check`, and
includes committed WAL content. Migration preserves original revisions and
seeds each preexisting running session once, retaining its ID and start time.
Backups are retained; migration or backup failure aborts opening the store.
The existing optional CloudKit configuration continues to synchronize only its
previous record table; nearby synchronization carries the timer revision table.
