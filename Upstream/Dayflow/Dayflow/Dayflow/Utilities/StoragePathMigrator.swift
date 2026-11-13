import Foundation

// LifeRecord never moves, merges, reads, or deletes the user's existing Dayflow files.
enum StoragePathMigrator {
  static func migrateIfNeeded() {}
}
