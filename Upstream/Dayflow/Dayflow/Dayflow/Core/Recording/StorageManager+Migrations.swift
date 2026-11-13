import Foundation

extension StorageManager {
  // Cross-application and sandbox migrations are intentionally disabled in this fork.
  func migrateLegacyChunkPathsIfNeeded() {}
  static func migrateDatabaseLocationIfNeeded(fileManager: FileManager, legacyRecordingsDir: URL, newDatabaseURL: URL) {}
}
