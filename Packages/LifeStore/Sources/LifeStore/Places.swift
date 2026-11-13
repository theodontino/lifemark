import Foundation
import GRDB
import LifeCore

/// A place the user named. It stays on the device that recorded it: only the name travels
/// with a time record, never the coordinates.
public struct SavedPlace: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double = 150) {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude; self.radius = radius
    }
}

public enum PlaceBook {
    static let key = "life.places"
    public static func load(_ defaults: UserDefaults = .standard) -> [SavedPlace] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
    }
    public static func save(_ places: [SavedPlace], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(places), forKey: key)
    }
    /// Great-circle distance in meters.
    static func distance(_ a: (latitude: Double, longitude: Double), _ b: (latitude: Double, longitude: Double)) -> Double {
        let rad = Double.pi / 180, dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
    /// The closest saved place whose radius contains the coordinate.
    public static func match(_ coordinate: (latitude: Double, longitude: Double), in places: [SavedPlace]) -> SavedPlace? {
        places.map { ($0, distance(coordinate, ($0.latitude, $0.longitude))) }.filter { $0.1 <= $0.0.radius }.min { $0.1 < $1.1 }?.0
    }
}

extension LifeStore {
    /// Coordinates of every stay this device recorded, keyed by the time record made from it.
    private func visitCoordinates() throws -> [UUID: (latitude: Double, longitude: Double)] {
        let payloads = try database.read { db in try String.fetchAll(db, sql: "SELECT payload FROM locationEvidence") }
        var result: [UUID: (latitude: Double, longitude: Double)] = [:]
        for payload in payloads {
            guard let feature = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            let properties = feature["properties"] as? [String: Any] ?? feature
            guard let arrival = Self.locationDate(properties["arrival_date"] ?? properties["arrivalDate"]),
                  let departure = Self.locationDate(properties["departure_date"] ?? properties["departureDate"]),
                  let coordinate = Self.coordinate(of: feature) else { continue }
            result[Self.visitID(properties: properties, arrival: arrival, departure: departure)] = coordinate
        }
        return result
    }

    /// Names the place of one location stay and applies the name to other unconfirmed stays there.
    @discardableResult
    public func namePlace(for block: TimeBlock, name: String, defaults: UserDefaults = .standard) throws -> SavedPlace {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw LifeStoreError.invalidRecord("请填写地点名称，最多 40 个字。") }
        guard let coordinate = try visitCoordinates()[block.id] else {
            throw LifeStoreError.invalidRecord("这条停留的位置只保存在记录它的那台手机上，请在那台手机上给地点起名。")
        }
        var places = PlaceBook.load(defaults)
        let place: SavedPlace
        if let index = places.firstIndex(where: { $0.name == name }) {
            places[index].latitude = coordinate.latitude; places[index].longitude = coordinate.longitude
            place = places[index]
        } else {
            place = SavedPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
            places.append(place)
        }
        PlaceBook.save(places, defaults)
        try tagLocationClues(defaults: defaults)
        return place
    }

    /// Re-applies saved place names to location stays that are still waiting for review.
    public func tagLocationClues(defaults: UserDefaults = .standard) throws {
        let places = PlaceBook.load(defaults)
        let coordinates = try visitCoordinates()
        for block in timeBlocks where block.source == .location && block.status == .pending {
            guard let coordinate = coordinates[block.id] else { continue }
            let name = PlaceBook.match(coordinate, in: places)?.name
            guard name != block.place else { continue }
            var updated = block; updated.place = name
            try save(updated, ifUnchangedFrom: block)
        }
    }
}
