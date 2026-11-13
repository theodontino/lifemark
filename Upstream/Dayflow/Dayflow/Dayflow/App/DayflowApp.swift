//
//  DayflowApp.swift
//  Dayflow
//

import SwiftUI

struct AppRootView: View {
  @EnvironmentObject private var categoryStore: CategoryStore
  @Binding var isShowingGitHubStarPrompt: Bool
  @Binding var gitHubStarCount: Int?
  @Binding var gitHubStarPromptUsesBrowser: Bool
  @State private var isCheckingGitHubStar = false
  @State private var whatsNewNote: ReleaseNote? = nil
  @State private var activeWhatsNewVersion: String? = nil
  @State private var shouldMarkWhatsNewSeen = false
  @State private var goalFlowPresentation: DayGoalFlowPresentation? = nil
  @State private var isShowingGettingStartedTour = false
  @State private var isGettingStartedTourReplay = false

  var body: some View {
    ZStack {
      MainView(goalFlowPresentation: $goalFlowPresentation)
        .environmentObject(AppState.shared)
        .environmentObject(categoryStore)

      goalFlowOverlay

      gettingStartedTourOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      showGettingStartedTourIfPending()
      guard whatsNewNote == nil else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if let note = WhatsNewConfiguration.pendingReleaseForCurrentBuild() {
          whatsNewNote = note
          activeWhatsNewVersion = note.version
          shouldMarkWhatsNewSeen = true
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        showGitHubStarPromptIfEligible(source: "launch")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        showSurveyIfEligible(source: "launch")
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
      guard let release = WhatsNewConfiguration.latestRelease() else { return }
      whatsNewNote = release
      activeWhatsNewVersion = release.version
      shouldMarkWhatsNewSeen = release.version == currentAppVersion

      // Analytics: track manual view
      AnalyticsService.shared.capture(
        "whats_new_viewed_manual",
        [
          "version": release.version
        ])
    }
    .onReceive(NotificationCenter.default.publisher(for: .showGettingStartedTour)) { _ in
      isGettingStartedTourReplay = true
      withAnimation(.easeOut(duration: 0.25)) {
        isShowingGettingStartedTour = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { _ in
      showGitHubStarPromptIfEligible(source: "first_card")
      showSurveyIfEligible(source: "new_card")
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      showSurveyIfEligible(source: "app_active")
    }
    .onChange(of: whatsNewNote == nil) { _, isDismissed in
      if isDismissed {
        showGitHubStarPromptIfEligible(source: "launch")
        showSurveyIfEligible(source: "launch")
      }
    }
    .sheet(item: $whatsNewNote, onDismiss: handleWhatsNewDismissed) { note in
      ZStack {
        // Backdrop
        Color.black.opacity(0.4)
          .ignoresSafeArea()

        WhatsNewView(releaseNote: note) {
          closeWhatsNew()
        }
      }
      .resolveDayflowTheme()
    }
  }

  @ViewBuilder
  private var goalFlowOverlay: some View {
    if let goalFlowPresentation {
      DayGoalFlowOverlay(
        presentation: goalFlowPresentation,
        onDismiss: {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            self.goalFlowPresentation = nil
          }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
      .transition(.opacity.combined(with: .scale(scale: 0.985)))
      .zIndex(3)
    }
  }

  @ViewBuilder
  private var gettingStartedTourOverlay: some View {
    if isShowingGettingStartedTour {
      GettingStartedTourOverlay(
        isReplay: isGettingStartedTourReplay, onFinish: finishGettingStartedTour
      )
      .transition(.opacity)
      .zIndex(4)
    }
  }

  private func showGettingStartedTourIfPending() {
    guard UserDefaults.standard.bool(forKey: GettingStarted.Keys.tourPending) else { return }
    // Let the timeline's entrance animation land first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
      withAnimation(.easeOut(duration: 0.25)) {
        isShowingGettingStartedTour = true
      }
    }
  }

  private func finishGettingStartedTour() {
    UserDefaults.standard.set(false, forKey: GettingStarted.Keys.tourPending)
    withAnimation(.easeOut(duration: 0.2)) {
      isShowingGettingStartedTour = false
    }
    isGettingStartedTourReplay = false
  }

  private var canShowGitHubStarPrompt: Bool {
    !isShowingGitHubStarPrompt && whatsNewNote == nil && goalFlowPresentation == nil
      && !isShowingGettingStartedTour && !SurveyCenter.shared.isShowingSurvey
  }

  /// Keeps the star card off the day a survey was shown.
  private var surveyShownRecently: Bool {
    guard let shownAt = SurveyCenter.lastShownAt else { return false }
    return Date().timeIntervalSince(shownAt) < SurveyCenter.otherPromptGap
  }

  /// Surveys share the bottom-right corner with the star card, so only one shows at a time.
  private func showSurveyIfEligible(source: String) {
    SurveyCenter.shared.checkForSurvey(source: source) {
      whatsNewNote == nil && goalFlowPresentation == nil && !isShowingGitHubStarPrompt
        && !isCheckingGitHubStar && !isShowingGettingStartedTour
    }
  }

  /// Asks every 3 days, but only people whose gh CLI confirms Dayflow isn't starred.
  private func showGitHubStarPromptIfEligible(source: String) {
    guard canShowGitHubStarPrompt,
      !isCheckingGitHubStar,
      GitHubStarPromptState.isDue,
      !surveyShownRecently,
      StorageManager.shared.hasAnyTimelineCards()
    else { return }

    isCheckingGitHubStar = true
    Task {
      let (check, starCount) = await Task.detached(priority: .utility) {
        let check = GitHubStarPrompt.check()
        let isUnstarred = check.starredByRepo[GitHubStarPrompt.primaryRepoName] == false
        return (check, isUnstarred ? GitHubStarPrompt.stargazerCount() : nil)
      }.value
      isCheckingGitHubStar = false
      handleGitHubStarCheck(check, starCount: starCount, source: source)
    }
  }

  private func handleGitHubStarCheck(_ check: GitHubStarCheck, starCount: Int?, source: String) {
    let isDayflowStarred = check.starredByRepo[GitHubStarPrompt.primaryRepoName]

    if isDayflowStarred == true {
      GitHubStarPromptState.markDone()
      return
    }

    // Something else took the screen while gh was running; try again on the next trigger.
    guard canShowGitHubStarPrompt else { return }

    // No usable gh (missing, logged out, 1Password), so we can't verify the star.
    // Ask these people once, then only re-check gh every 3 days in case they set it up.
    guard isDayflowStarred == false else {
      GitHubStarPromptState.markAttempted()
      guard !GitHubStarPromptState.hasShownBrowserPrompt else { return }
      GitHubStarPromptState.markBrowserPromptShown()
      presentGitHubStarPrompt(check: check, starCount: nil, usesBrowser: true, source: source)
      return
    }

    GitHubStarPromptState.markShown()
    presentGitHubStarPrompt(check: check, starCount: starCount, usesBrowser: false, source: source)
  }

  private func presentGitHubStarPrompt(
    check: GitHubStarCheck, starCount: Int?, usesBrowser: Bool, source: String
  ) {
    var props = check.analyticsProperties
    props["source"] = source
    props["variant"] = usesBrowser ? "browser" : "gh"
    props["prompt_number"] = GitHubStarPromptState.shownCount
    if let starCount { props["star_count"] = starCount }
    AnalyticsService.shared.capture("github_star_prompt_shown", props)

    gitHubStarCount = starCount
    gitHubStarPromptUsesBrowser = usesBrowser
    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
      isShowingGitHubStarPrompt = true
    }
  }

  private func closeWhatsNew() {
    whatsNewNote = nil
  }

  private func handleWhatsNewDismissed() {
    guard let version = activeWhatsNewVersion else { return }
    if shouldMarkWhatsNewSeen {
      WhatsNewConfiguration.markReleaseAsSeen(version: version)
      AnalyticsService.shared.capture(
        "whats_new_viewed",
        [
          "version": version,
          "source": "auto",
        ])
    }
    AnalyticsService.shared.capture(
      "whats_new_viewed",
      [
        "version": version,
        "source": "manual",
      ])
    activeWhatsNewVersion = nil
    shouldMarkWhatsNewSeen = false
    showGitHubStarPromptIfEligible(source: "launch")
  }

  private var currentAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  init() {
    // A launcher may close stdout before the app exits.
    signal(SIGPIPE, SIG_IGN)
  }

  var body: some Scene {
    Window("人生记录", id: "life") {
      LifeMacRoot()
        .background { MainWindowRegistrationView() }
    }
    .defaultSize(width: 1100, height: 780)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) {}
      CommandGroup(replacing: .help) {}
      CommandMenu("记录") {
        Button("显示人生记录") {
          MainWindowController.shared.showMainWindow()
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let analyticsPreferenceChanged = Notification.Name("analyticsPreferenceChanged")
  static let showWhatsNew = Notification.Name("showWhatsNew")
  static let showGettingStartedTour = Notification.Name("showGettingStartedTour")
  static let navigateToDaily = Notification.Name("navigateToDaily")
  static let navigateToSupport = Notification.Name("navigateToSupport")
  static let navigateToWeekly = Notification.Name("navigateToWeekly")
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let hideTimelineFailureToast = Notification.Name("hideTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
  static let openAccountSettings = Notification.Name("openAccountSettings")
  static let navigateToFlow = Notification.Name("navigateToFlow")
  static let navigateToTimeline = Notification.Name("navigateToTimeline")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "life")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "life")
  }
}

/// Full-window gradient behind the main app (Figma: dark linear / light radial).
private struct DayflowWindowBackground: View {
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    GeometryReader { proxy in
      if theme.isDark {
        Image("DarkWindowBackground")
          .resizable()
          .interpolation(.high)
          .scaledToFill()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
      } else {
        LightWindowGradient()
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
  }
}

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
