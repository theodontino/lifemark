# Timer system surfaces

The app and LifeTimerActivity extension compile the same TimeActivityAttributes definition. The extension has no LifeStore, database, cloud credentials, network calls, or access to raw captures. It renders task title/category and system-managed elapsed Text(start, style: .timer) for lock screen and all Dynamic Island modes.

TimerActivityController installs once from the app's hosting-controller bridge. It reconciles on LifeRecord.timersChanged and UIApplication.didBecomeActiveNotification, ends surfaces for stopped timers, and starts only if running local timers already exist, the app is active, and ActivityAuthorizationInfo allows activities. It never requests notification permission or a push token. Request failures report LifeRecord.timerActivityStatus with userInfo["status"]; the local timer is not altered.

A successful Activity request is remembered per running timer ID. A dismissed/system-ended surface is not repeatedly recreated just because the app becomes active. Local timers longer than eight hours keep running in LifeStore; the controller explains the system display limit instead of finishing the user's timer. There is no per-second timer, sleeping loop, background network or server requirement.

The app registers liferecord://timers; the extension uses widgetURL to open it. SceneDelegate posts LifeRecord.showTimer; LifeRootView selects its timer page. Ending a timer occurs through the app's explicit user action.

Primary API sources read for this implementation:
- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/activitykit/activity/attributes

Apple documents an active lifetime up to eight hours and possible lock-screen retention up to four additional hours; actual system presentation, capacity, dismissal and device eligibility are outside app control. A source build without signing proves compilation only. Activity requests and the lock-screen/Dynamic Island result must still be checked on a signed physical device; build/test steps do not start activities.

## Build verification

Generic iOS device build with signing disabled succeeded for LifeRecordiOS and its embedded LifeTimerActivity extension. The built app Info.plist contains NSSupportsLiveActivities=true and the liferecord URL scheme; the embedded extension has bundle ID local.liferecord.ios.timeractivity and WidgetKit extension point, minimum iOS 17. The Widget/Attributes files also passed an independent iOS SDK typecheck. No runtime Activity request, lock-screen display, Dynamic Island presentation, background operation or signed device installation was exercised.
