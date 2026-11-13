#if os(iOS)
import Foundation
import Observation
import WatchConnectivity
import LifeStore

/// The phone owns timer mutations; the watch sends reachable, interactive requests only.
@MainActor
final class PhoneWatchTimerBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchTimerBridge()
    private var installed = false
    private(set) var connectionError: String?

    func install() {
        guard !installed, WCSession.isSupported() else { return }
        installed = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        observeStore()
    }

    private func observeStore() {
        guard let store = LifeIntegrationStore.shared else { return }
        withObservationTracking {
            _ = store.runningTimers
            _ = store.timeBlocks
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeStore()
                self?.publishContext()
            }
        }
    }

    private func snapshot(error: String? = nil) -> [String: Any] {
        let defaults = UserDefaults.standard
        let epoch = defaults.string(forKey: "life.watch.snapshotEpoch") ?? UUID().uuidString
        defaults.set(epoch, forKey: "life.watch.snapshotEpoch")
        let version = defaults.integer(forKey: "life.watch.snapshotVersion") + 1
        defaults.set(version, forKey: "life.watch.snapshotVersion")
        var result: [String: Any] = ["epoch": epoch, "version": version]
        guard let store = LifeIntegrationStore.shared else {
            result["timers"] = [[String: Any]]()
            result["recent"] = [[String: String]]()
            result["error"] = LifeIntegrationStore.openingError ?? "无法读取手机上的计时记录。"
            return result
        }
        result["timers"] = store.runningTimers.map { timer -> [String: Any] in
            ["id": timer.id.uuidString, "title": String(timer.title.prefix(160)), "category": String(timer.category.prefix(60)),
             "start": timer.start.timeIntervalSince1970]
        }
        var seen = Set<[String]>()
        var recent: [[String: String]] = []
        for block in store.timeBlocks.filter({ $0.status == .confirmed }).sorted(by: { $0.end > $1.end }) {
            let pair = [block.title, block.category]
            guard seen.insert(pair).inserted else { continue }
            recent.append(["title": String(block.title.prefix(160)), "category": String(block.category.prefix(60))])
            if recent.count == 8 { break }
        }
        result["recent"] = recent
        if let error { result["error"] = error }
        return result
    }

    private func publishContext() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(snapshot())
            connectionError = nil
        } catch {
            // Context delivery is best effort. Interactive replies still carry the latest state.
            connectionError = "手表状态同步失败：\(error.localizedDescription)"
        }
    }

    private func receive(_ message: [String: Any]) -> [String: Any] {
        do {
            let store = try LifeIntegrationStore.result.get()
            switch message["action"] as? String {
            case "refresh": break
            case "start":
                guard let rawTitle = message["title"] as? String,
                      rawTitle.count <= 160,
                      let rawRequestID = message["requestID"] as? String,
                      rawRequestID.count == 36, let requestID = UUID(uuidString: rawRequestID) else {
                    return snapshot(error: "开始计时的内容无效，请刷新后重试。")
                }
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawCategory = message["category"] as? String ?? "工作"
                guard !title.isEmpty, rawCategory.count <= 60 else {
                    return snapshot(error: "请填写事项（最多160字），分类最多60字。")
                }
                let category = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                guard store.runningTimers.isEmpty || store.runningTimers.contains(where: { $0.id == requestID }) else {
                    return snapshot(error: "手机已有正在计时的事项，请先结束当前事项。")
                }
                // The persisted timer ID is the request ID: a lost reply cannot create a duplicate.
                _ = try store.startTimer(title: title, category: category.isEmpty ? "工作" : category,
                                         at: Date(), id: requestID)
            case "cancel":
                guard let rawID = message["timerID"] as? String, let id = UUID(uuidString: rawID) else {
                    return snapshot(error: "计时编号无效，请刷新后重试。")
                }
                try store.cancelTimer(id: id)
            case "finish":
                guard let rawID = message["timerID"] as? String, rawID.count == 36,
                      let id = UUID(uuidString: rawID) else {
                    return snapshot(error: "计时编号无效，请刷新后重试。")
                }
                if let timer = store.runningTimers.first(where: { $0.id == id }), Date().timeIntervalSince(timer.start) > 7 * 24 * 3600 {
                    return snapshot(error: "这次计时超过7天，请在手机核对实际结束时间；也可以在手表放弃计时。")
                }
                _ = try store.finishTimer(id: id, at: Date())
            default:
                return snapshot(error: "无法识别手表请求，请更新手表应用。")
            }
            NotificationCenter.default.post(name: TimerActivityController.changed, object: nil)
            publishContext()
            return snapshot()
        } catch {
            publishContext()
            return snapshot(error: error.localizedDescription)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in replyHandler(self.receive(message)) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.connectionError = error.map { "手表连接失败：\($0.localizedDescription)" }
            if error == nil { self.publishContext() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishContext() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishContext() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in WCSession.default.activate() }
    }
}
#endif
