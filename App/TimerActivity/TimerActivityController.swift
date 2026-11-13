#if os(iOS)
import ActivityKit
import Foundation
import UIKit
import LifeStore

/// Only reconciles when the app is active or timer records change. SwiftUI renders elapsed
/// seconds in the system surface; this controller never runs a per-second background task.
@MainActor
final class TimerActivityController {
    static let shared = TimerActivityController()
    static let changed = Notification.Name("LifeRecord.timersChanged")
    static let statusChanged = Notification.Name("LifeRecord.timerActivityStatus")
    private let attemptedKey = "lifeRecord.requestedTimerActivities"
    private var observers: [NSObjectProtocol] = []
    private var isReconciling = false
    private var needsReconcile = false
    private var requestedIDs: Set<String>
    private(set) var status = "本机计时独立保存；灵动岛和锁屏显示由系统决定。"

    private init() {
        requestedIDs = Set(UserDefaults.standard.stringArray(forKey: attemptedKey) ?? [])
    }

    func install() {
        guard observers.isEmpty else { return }
        for name in [Self.changed, LifeStore.didChangeNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.reconcile() }
            })
        }
        Task { await reconcile() }
    }

    func reconcile() async {
        if isReconciling { needsReconcile = true; return }
        isReconciling = true
        defer { isReconciling = false }
        repeat {
            needsReconcile = false
            await reconcileSnapshot()
        } while needsReconcile
    }

    private func reconcileSnapshot() async {
        guard let store = LifeIntegrationStore.shared else {
            publish("无法读取本机计时记录，锁屏显示暂不可用。")
            return
        }
        let timers = store.runningTimers
        let ids = Set(timers.map { $0.id.uuidString })
        requestedIDs.formIntersection(ids)
        let now = Date()
        var notes: [String] = []
        var activities = Activity<TimeActivityAttributes>.activities
        // An ended/deleted timer must not leave a live system surface behind.
        for activity in activities where !ids.contains(activity.attributes.timerID) {
            var state = activity.content.state
            state.isRunning = false
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        activities.removeAll { !ids.contains($0.attributes.timerID) }
        guard UIApplication.shared.applicationState == .active else {
            publish("本机计时已保存；打开应用后对齐锁屏显示。")
            return
        }
        let allowed = ActivityAuthorizationInfo().areActivitiesEnabled
        for timer in timers {
            let id = timer.id.uuidString
            let matching = activities.filter { $0.attributes.timerID == id }
            // Keep the system payload below ActivityKit's limit; the full title stays in LifeStore.
            let state = TimeActivityAttributes.ContentState(title: String(timer.title.prefix(160)),
                                                            category: String(timer.category.prefix(60)), isRunning: true)
            // ActivityKit has a finite display lifetime; never truncate the user's actual timer.
            if now.timeIntervalSince(timer.start) >= 8 * 60 * 60 {
                for activity in matching {
                    await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
                }
                notes.append("计时已超过系统实时活动的约 8 小时显示期限，本机计时继续。")
                continue
            }
            if let activity = matching.first {
                await activity.update(ActivityContent(state: state, staleDate: timer.start.addingTimeInterval(8 * 60 * 60)))
                for duplicate in matching.dropFirst() {
                    await duplicate.end(nil, dismissalPolicy: .immediate)
                }
                continue
            }
            guard allowed else {
                notes.append("系统未允许实时活动；本机计时正常，可在应用内查看和结束。")
                continue
            }
            // Do not repeatedly resurrect a system-ended or user-dismissed activity.
            guard !requestedIDs.contains(id) else {
                notes.append("部分锁屏计时已被系统结束或隐藏，本机计时继续；打开应用可结束。")
                continue
            }
            do {
                _ = try Activity.request(attributes: TimeActivityAttributes(timerID: id, start: timer.start),
                                         content: ActivityContent(state: state, staleDate: timer.start.addingTimeInterval(8 * 60 * 60)),
                                         pushType: nil)
                requestedIDs.insert(id)
            } catch {
                notes.append("锁屏计时暂不可用：\(error.localizedDescription)。本机计时不受影响。")
            }
        }
        UserDefaults.standard.set(Array(requestedIDs).sorted(), forKey: attemptedKey)
        if timers.isEmpty {
            publish("尚未开始计时。开始后可在支持的 iPhone 锁屏与灵动岛查看。")
        } else if notes.isEmpty {
            publish("锁屏计时已对齐；灵动岛由机型与系统决定。约 8 小时显示期限不影响本机计时。")
        } else {
            publish(Array(Set(notes)).sorted().joined(separator: "\n"))
        }
    }

    private func publish(_ message: String) {
        status = message
        NotificationCenter.default.post(name: Self.statusChanged, object: nil, userInfo: ["status": message])
    }
}
#endif
