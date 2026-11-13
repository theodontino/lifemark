import SwiftUI
import WatchConnectivity

private struct WatchTimer: Identifiable {
    let id: String
    let title: String
    let category: String
    let start: Date
}
private struct RecentTask: Identifiable {
    var id: String { title + "\u{0}" + category }
    let title: String
    let category: String
}

@MainActor private final class WatchTimerLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var timers: [WatchTimer] = []
    @Published var recent: [RecentTask] = []
    @Published var busy = false
    @Published var reachable = false
    @Published var message = "正在连接手机…"
    @Published var pending: [String: String]?
    private var newestSnapshot = 0.0
    private var snapshotEpoch = ""
    private let session = WCSession.default
    private let cacheKey = "life.watch.timerSnapshot"
    private let pendingKey = "life.watch.pendingCommand"

    override init() {
        super.init()
        pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: String]
        if let cached = UserDefaults.standard.dictionary(forKey: cacheKey) { apply(cached) }
        message = "显示上次状态，正在连接手机…"
        session.delegate = self
        session.activate()
    }
    func refresh() { send(["action": "refresh"]) }
    func start(_ title: String, category: String = "工作") {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, pending == nil, timers.isEmpty else { return }
        command(["action": "start", "title": String(value.prefix(160)), "category": category,
                 "requestID": UUID().uuidString])
    }
    func finish(_ id: String) {
        guard pending == nil else { return }
        command(["action": "finish", "timerID": id, "requestID": UUID().uuidString])
    }
    func cancel(_ id: String) {
        guard pending == nil else { return }
        command(["action": "cancel", "timerID": id, "requestID": UUID().uuidString])
    }
    func retry() { if let pending { send(pending) } }
    private func command(_ value: [String: String]) {
        pending = value
        UserDefaults.standard.set(value, forKey: pendingKey)
        send(value)
    }
    private func send(_ value: [String: String]) {
        guard !busy else { return }
        reachable = session.activationState == .activated && session.isReachable
        guard reachable else {
            message = "暂时连不上 iPhone。请把手机放在附近，并打开一次人生记录。"
            return
        }
        busy = true
        let isCommand = value["action"] != "refresh"
        session.sendMessage(value, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.apply(reply)
                if isCommand {
                    self.pending = nil
                    UserDefaults.standard.removeObject(forKey: self.pendingKey)
                }
                self.message = reply["error"] as? String ?? "已与手机对齐"
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.reachable = self.session.isReachable
                self.message = isCommand ? "手机还没确认结果。请重试上次操作，避免重复计时。" : "暂时连不上手机，显示上次状态。"
            }
        })
    }
    private func apply(_ data: [String: Any]) {
        guard let epoch = data["epoch"] as? String, let stamp = (data["version"] as? NSNumber)?.doubleValue,
              (epoch != snapshotEpoch || stamp >= newestSnapshot),
              let rows = data["timers"] as? [[String: Any]],
              let history = data["recent"] as? [[String: String]] else { return }
        newestSnapshot = stamp
        snapshotEpoch = epoch
        timers = rows.compactMap { row in
            guard let id = row["id"] as? String, let title = row["title"] as? String,
                  let category = row["category"] as? String, let start = row["start"] as? Double,
                  start.isFinite else { return nil }
            return WatchTimer(id: id, title: title, category: category, start: Date(timeIntervalSince1970: start))
        }
        recent = history.compactMap { row in
            guard let title = row["title"], let category = row["category"] else { return nil }
            return RecentTask(title: title, category: category)
        }
        UserDefaults.standard.set(["epoch": epoch, "version": stamp, "timers": rows, "recent": history], forKey: cacheKey)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = self.session.isReachable
            if self.reachable { self.refresh() }
            else { self.message = "手机未连接，显示上次状态。" }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
}

@main struct LifeWatchApp: App {
    @StateObject private var link = WatchTimerLink()
    @Environment(\.scenePhase) private var scenePhase
    @State private var title = ""
    @State private var cancellingID: String?
    @State private var confirmingCancel = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if link.timers.isEmpty {
                            Text("现在做什么？").font(.headline)
                            TextField("输入或口述事项", text: $title).disabled(link.pending != nil)
                            Button("开始计时", systemImage: "play.fill") { link.start(title) }
                                .tint(.mint).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canOperate)
                            ForEach(tasks) { task in
                                Button { link.start(task.title, category: task.category) } label: {
                                    HStack { Text(task.title).lineLimit(2); Spacer(); Image(systemName: "play.fill") }
                                }.disabled(!canOperate)
                            }
                        } else {
                            ForEach(link.timers) { timer in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(timer.title).font(.headline)
                                    Text(timer.start, style: .timer).font(.system(.title2, design: .monospaced)).foregroundStyle(.mint)
                                    Text(timer.category).font(.caption).foregroundStyle(.secondary)
                                    Button("结束并保存", systemImage: "stop.fill") { link.finish(timer.id) }
                                        .tint(.orange).disabled(!canOperate || Date().timeIntervalSince(timer.start) > 7 * 24 * 3600)
                                    if Date().timeIntervalSince(timer.start) > 7 * 24 * 3600 { Text("长计时请在手机核对实际结束时间，或放弃这次计时。").font(.caption2) }
                                    Button("放弃计时…", role: .destructive) { cancellingID = timer.id; confirmingCancel = true }.disabled(!canOperate)
                                }
                            }
                            Text("结束后可选择下一项").font(.caption).foregroundStyle(.secondary)
                        }
                        if link.busy { ProgressView("等待手机确认") }
                        Text(link.message).font(.caption2).foregroundStyle(.secondary)
                        if link.pending != nil {
                            Button("重试上次操作") { link.retry() }.disabled(link.busy || !link.reachable)
                        }
                        Button("刷新手机状态", systemImage: "arrow.clockwise") { link.refresh() }.disabled(link.busy)
                    }.padding(.horizontal, 4)
                }.navigationTitle("人生计时")
            }
            .confirmationDialog("放弃计时？不会生成记录。", isPresented: $confirmingCancel) {
                Button("放弃计时", role: .destructive) { if let id = cancellingID { link.cancel(id) } }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { link.refresh() } }
        }
    }
    private var canOperate: Bool { link.reachable && !link.busy && link.pending == nil }
    private var tasks: [RecentTask] {
        link.recent.isEmpty ? [RecentTask(title: "备课", category: "工作"), RecentTask(title: "上课", category: "工作"),
                               RecentTask(title: "吃饭", category: "生活"), RecentTask(title: "休息", category: "生活")] : link.recent
    }
}
