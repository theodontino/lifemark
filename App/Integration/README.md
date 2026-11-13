# Upstream integration record

## Pinned source and licenses

- Dayflow: JerryZLiu/Dayflow, commit `33517b1c3a8c5df2b0f9589f0bff284b7dd4f669`; root `Upstream/Dayflow/LICENSE` is MIT (Jerry Liu). Keep original copyright and license notices. Mac capture, local screen storage, AI generation and its original time model remain upstream-owned modules.
- Overland: aaronpk/Overland-iOS, commit `9552753ed4c0db010e7b49f6be9d97b2ad21f0a6`; `Upstream/Overland/LICENSE` is Apache-2.0. Original Esri/Aaron Parecki/Geoloqi source copyright headers remain. Upstream README separately attributes Material Symbols under Apache-2.0. The existing iCloud Drive outlet writes GeoJSON files, not CloudKit record synchronization.
- FMDB: ccgus/fmdb tag `2.7.12`, commit `1227a3fa2b9916bfd75fe380eb45cd210e69e251`; `Upstream/FMDB/LICENSE.txt` is MIT (Flying Meat). CocoaPods is not required: compile the six `.m` files under `src/fmdb`, add `src/fmdb` and `include` to header search paths, link system sqlite3, and include the supplied `privacy/PrivacyInfo.xcprivacy`. Added `include/fmdb/FMDatabase.h` only forwards the existing lowercase upstream include to the vendored header.

Root licenses do not replace notices for separately linked dependencies. Dayflow's Package.resolved additionally pins GRDB, NetworkImage, PostHog, Sentry, Sparkle, swift-cmark and MarkdownUI. Screenpipe code is not included.

## Application boundary

`LifeIntegrationStore.swift` creates one LifeStore per process. Opening errors remain visible and never erase or replace the database. The optional `LifeCloudContainerIdentifier` Info.plist value configures the shared store. Without signed iCloud capability, local recording remains usable and cloud setup is a later deployment step.

On iOS `OverlandLifeIntegration.swift` creates a UIHostingController for LifeUI's shared `LifeRootView`. SceneDelegate installs it as the single root controller; the existing Tracker/Settings controller is retained in the shared settings page's capture sheet. Keep `PRODUCT_MODULE_NAME = Overland` (or update all upstream `Overland-Swift.h` imports consistently) and the original bridging header. No call starts tracking or requests access as part of this UI installation; the original user-operated tracking/settings controls remain.

GLManager's `sendQueueNow` now transfers a bounded batch of raw GeoJSON records to LifeStore. Its completion means local persistence, not an iCloud acknowledgement. Queue keys are removed only after the store commits; failures leave the original batch intact and update the existing error banner. Partial visits and raw points must be retained in the store's local-only evidence table even when no complete activity can be inferred. Cloud sync is separate. Local commits ignore former network interval/Wi-Fi restrictions. The previous HTTP/iCloud Drive sender remains named `legacySendQueueNow` for reference and has no call sites. `hasDestination` reflects the always-present local destination, and the local path uses full GeoJSON rather than OwnTracks format. Tracker's commit button is labeled 保存到生活; Wi-Fi/resource transfer warnings are disabled for this local outlet. The original advanced network/export settings are retained upstream controls; they do not switch this fork's local commit outlet to networking. The fork uses isolated group.local.liferecord and iCloud.local.liferecord identifiers for retained auxiliary features, which need their own signing configuration before use.

StorageManager posts timelineDataUpdated after successful narrow timeline mutations, even when the original timeline view is closed. Mac summary import excludes onboarding dummy cards (no batch) and System failure cards; a throwing complete snapshot is reconciled in LifeStore so failed reads cannot erase existing records.

Mac summary import is implemented separately in `DayflowLifeIntegration.swift`. It imports time/title/category/summary only. Screenshots, HEVC frames, accessibility transcripts, and the internal capture database are not copied into CloudKit or a server. The original single-screen-track validation stays intact; manual/location/concurrent life events belong to LifeStore instead.

## Verification boundary

Fetching pinned source does not prove the original applications build on every SDK. Main owns project generation and platform builds. Integration must be checked with the generated targets, then permission, native input, background delivery and signed CloudKit behavior must be exercised on actual devices by user action. No integration test should request capture/location permission or begin capturing automatically.

## Independent fork isolation

The embedded Dayflow engine uses `Application Support/LifeRecord` for frames, its chunks database, backups, accessibility logs, timelapses, CLI work files, agent data and privacy-model cache. CLI/agent defaults use `local.liferecord.mac`; API-key and upstream-account Keychain services use separate `local.liferecord.*` names. UserDefaultsMigrator, StoragePathMigrator and legacy chunk/database relocation entry points are deliberately no-ops: no existing Dayflow directory, container, preferences or credential is imported, merged, moved or removed.

PostHog initialization/opt-in and Sentry wrapper APIs are no-ops in this fork. UpdaterManager retains observable UI properties but never instantiates Sparkle; CLIAutoUpdater never changes installed CLI tools. Launch-at-login automatic enabling is disabled; its explicit user settings action remains. AppDelegate starts screen recording paused on every launch, with the original manual recording controls retained. Default upstream account/support/Flow services, referral usage upload and MCP registration repair are not started. These are source-level isolation changes; full platform compilation and runtime network observation remain separate checks.
