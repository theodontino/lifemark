import Foundation
import Testing
import LifeCore
@testable import LifeStore

@MainActor struct PlaceTests {
    func visit(_ lon: Double, _ lat: Double, _ arrive: String, _ leave: String) -> Data {
        Data(#"{"locations":[{"type":"Feature","geometry":{"type":"Point","coordinates":[\#(lon),\#(lat)]},"properties":{"action":"visit","arrival_date":"\#(arrive)","departure_date":"\#(leave)"}}]}"#.utf8)
    }
    func scratch() -> UserDefaults {
        let name = "PlaceTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
    @Test func namingOnePlaceTagsOtherStaysThereAndLaterVisits() throws {
        let store = try LifeStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("PlaceTests-\(UUID()).sqlite"))
        let defaults = scratch()
        try store.importLocationFeatures(visit(120.0000, 30.0000, "2026-11-12T01:00:00Z", "2026-11-12T02:00:00Z"), defaults: defaults)
        try store.importLocationFeatures(visit(120.0005, 30.0003, "2026-11-12T05:00:00Z", "2026-11-12T06:00:00Z"), defaults: defaults)
        try store.importLocationFeatures(visit(121.0000, 31.0000, "2026-11-12T08:00:00Z", "2026-11-12T09:00:00Z"), defaults: defaults)
        #expect(store.timeBlocks.allSatisfy { $0.place == nil })
        let first = try #require(store.timeBlocks.min { $0.start < $1.start })
        try store.namePlace(for: first, name: " 学校 ", defaults: defaults)
        let tagged = store.timeBlocks.sorted { $0.start < $1.start }.map(\.place)
        #expect(tagged == ["学校", "学校", nil])
        #expect(PlaceBook.load(defaults).map(\.name) == ["学校"])
        // A later visit to the same place carries the name from the start.
        try store.importLocationFeatures(visit(120.0002, 30.0001, "2026-11-13T01:00:00Z", "2026-11-13T02:00:00Z"), defaults: defaults)
        #expect(store.timeBlocks.max { $0.start < $1.start }?.place == "学校")
        // The name travels with the record; coordinates do not.
        let payload = try LifeStore.encode(try #require(store.timeBlocks.first { $0.place != nil }))
        #expect(payload.contains("学校") && !payload.contains("120.0"))
    }
    @Test func recordsWithoutPlaceEncodeExactlyAsBefore() throws {
        let block = TimeBlock(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "备课", category: "工作",
                              start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))
        #expect(try !LifeStore.encode(block).contains("place"))
    }
    @Test func namingNeedsTheDeviceThatRecordedTheStay() throws {
        let store = try LifeStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("PlaceTests-\(UUID()).sqlite"))
        let foreign = TimeBlock(title: "定位停留（待确认）", category: "未分类", start: Date(timeIntervalSince1970: 1_800_000_000),
                                end: Date(timeIntervalSince1970: 1_800_003_600), source: .location, status: .pending)
        try store.save(foreign)
        #expect(throws: (any Error).self) { try store.namePlace(for: foreign, name: "家", defaults: scratch()) }
    }
}
