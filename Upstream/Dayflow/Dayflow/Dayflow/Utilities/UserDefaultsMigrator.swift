import Foundation

// LifeRecord is a separate application. Never import preferences from another app/container.
enum UserDefaultsMigrator {
  static func migrateIfNeeded(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {}
}
