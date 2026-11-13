import Foundation
import Combine

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
  static let shared = UpdaterManager()
  @Published var isChecking = false
  @Published var statusText = "此独立版本不使用上游自动更新"
  @Published var updateAvailable = false
  @Published var latestVersionString: String? = nil
  func checkForUpdates(showUI: Bool = false) {
    statusText = "此独立版本不使用上游自动更新"
  }
}
