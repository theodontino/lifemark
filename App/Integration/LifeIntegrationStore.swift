import Foundation
import LifeStore
import LifeNearby

/// One local store per process. A failed opening is shown to the user; it never creates a replacement database.
@MainActor
enum LifeIntegrationStore {
    static let result: Result<LifeStore, Error> = Result {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "LifeCloudContainerIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let container = configured.flatMap { $0.isEmpty ? nil : $0 }
        return try LifeStore(cloudContainerIdentifier: container)
    }

    static var shared: LifeStore? {
        switch result {
        case .success(let store): return store
        case .failure: return nil
        }
    }

    static let nearby: NearbySyncController? = shared.map { NearbySyncController(store: $0) }

    static var openingError: String? {
        switch result {
        case .success: return nil
        case .failure(let error): return "生活记录数据库无法打开：\(error.localizedDescription)。原数据已保留，请检查存储空间或重新打开应用。"
        }
    }
}
