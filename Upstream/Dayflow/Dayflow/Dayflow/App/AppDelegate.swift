//
//  AppDelegate.swift
//  LifeRecord's host for the preserved Dayflow screen recorder.
//

import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  // Kept for source compatibility with the retained upstream permission views.
  enum PendingNotificationNavigationDestination: Equatable {
    case daily(day: String?)
    case weekly
    case support
    case flow
    case timeline
  }
  static var pendingNotificationNavigationDestination: PendingNotificationNavigationDestination?
  static var allowTermination = false
  static var terminationReason = "unknown"

  static func permitTermination(reason: String) {
    allowTermination = true
    terminationReason = reason
  }

  private var recorder: ScreenRecorder?

  override init() {
    FlippedTextLayerWorkaround.install()
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)

    // Capture never resumes merely because the app launched or received an old URL.
    AppState.shared.setRecording(false, analyticsReason: "auto", persistPreference: false)
    recorder = ScreenRecorder(autoStart: false)
    AppState.shared.enablePersistence()

    // LifeRecord owns permission, model setup and opt-in analysis from this point on.
    LifeScreenModule.shared.install()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainWindowController.shared.showMainWindow()
    sender.activate(ignoringOtherApps: true)
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    // Upstream dayflow:// actions include recording and account/referral flows.
    // Legacy URLs now only bring the unified LifeRecord window to the foreground.
    guard !urls.isEmpty else { return }
    MainWindowController.shared.showMainWindow()
    application.activate(ignoringOtherApps: true)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard Self.pendingNotificationNavigationDestination != nil else { return }
    Self.pendingNotificationNavigationDestination = nil
    MainWindowController.shared.showMainWindow()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Explicitly enabled capture may continue while the main window is closed.
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    LifeScreenModule.shared.setEnabled(false)
    Self.permitTermination(reason: "user_quit")
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    LifeScreenModule.shared.setEnabled(false)
    StorageManager.shared.checkpoint(mode: .truncate)
  }
}
