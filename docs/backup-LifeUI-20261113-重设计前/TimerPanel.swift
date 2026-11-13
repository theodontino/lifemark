import SwiftUI
import LifeCore
import LifeStore

@MainActor struct TimerPanel: View {
    let store: LifeStore
    @State private var title = ""
    @State private var category = "工作"
    @State private var cancellingID: UUID?
    @State private var confirmingCancel = false
    @State private var overdueTimer: RunningTimer?
    @State private var actualEnd = Date()
    @State private var error: String?
    @State private var activityStatus = ""
    @FocusState private var focused: Bool
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Panel("现在正在做什么？") {
            TextField("输入事项，例如：备课、读书、处理消息", text: $title)
                .textFieldStyle(.roundedBorder).font(.title3).focused($focused)
                .onSubmit { if store.runningTimers.isEmpty { begin(replacing: false) } else { focused = false } }
            Picker("类别", selection: $category) { ForEach(timeCategories, id: \.self) { Text($0).tag($0) } }
                .frame(maxWidth: 260)
            HStack {
                if store.runningTimers.count == 1 {
                    Button("结束当前，开始这一项") { begin(replacing: true) }
                        .buttonStyle(.borderedProminent).disabled(cleanTitle.isEmpty)
                    Button("并行开始") { begin(replacing: false) }
                        .buttonStyle(.bordered).disabled(cleanTitle.isEmpty)
                } else {
                    Button { begin(replacing: false) } label: {
                        Label(store.runningTimers.isEmpty ? "开始计时" : "并行开始", systemImage: "play.fill")
                    }.buttonStyle(.borderedProminent).disabled(cleanTitle.isEmpty)
                }
            }.controlSize(.large)
            if store.runningTimers.isEmpty {
                Text("开始后可以离开 App；结束时间由你手动确认，重开后继续计算已过时间。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(store.runningTimers) { timer in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(timer.title, systemImage: "record.circle").font(.headline)
                            Spacer()
                            Text(timer.category).font(.caption).foregroundStyle(.secondary)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsed(context.date.timeIntervalSince(timer.start)))
                                .font(.system(size: 42, weight: .medium, design: .monospaced))
                                .foregroundStyle(lifeAccent)
                        }
                        HStack {
                            Text("开始于 " + timer.start.formatted(.dateTime.month().day().hour().minute()))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("结束并保存") { requestFinish(timer) }.buttonStyle(.borderedProminent)
                        }
                        Button("放弃这次计时…", role: .destructive) { cancellingID = timer.id; confirmingCancel = true }
                            .font(.caption)
                    }.padding(16).background(lifeAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                Text("结束后直接保存为实际时间记录。输入下一项即可切换；并行事项分别结束。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if os(iOS)
            Text(activityStatus.isEmpty ? "允许实时活动且设备支持时，会在锁屏和灵动岛显示计时。点击活动可返回 App 结束。" : activityStatus)
                .font(.caption).foregroundStyle(.secondary)
            #endif
            ErrorText(text: error)
        }.confirmationDialog("放弃这次计时？不会生成时间记录。", isPresented: $confirmingCancel) {
            Button("放弃计时", role: .destructive) {
                guard let id = cancellingID else { return }
                do { try store.cancelTimer(id: id); notify(); error = nil } catch { self.error = error.localizedDescription }
            }
        }.sheet(item: $overdueTimer) { timer in
            NavigationStack {
                Form {
                    Text("这次计时已超过7天。请核对实际结束时间，避免把忘记结束的时间算进去。")
                    DatePicker("实际结束", selection: $actualEnd, in: timer.start...Date())
                    ErrorText(text: error)
                    Button("核对完成，结束并保存") { finish(timer.id, at: actualEnd) }
                }.padding().navigationTitle("核对结束时间")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { overdueTimer = nil } } }
            }.frame(idealWidth: 420, idealHeight: 300)
        }.onReceive(NotificationCenter.default.publisher(for: Notification.Name("LifeRecord.timerActivityStatus"))) { note in
            activityStatus = note.userInfo?["status"] as? String ?? ""
        }
    }
    private func elapsed(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func notify() { NotificationCenter.default.post(name: Notification.Name("LifeRecord.timersChanged"), object: nil) }
    private func begin(replacing: Bool) {
        guard !cleanTitle.isEmpty else { return }
        error = nil
        do {
            if replacing, let current = store.runningTimers.first, store.runningTimers.count == 1 {
                guard Date().timeIntervalSince(current.start) <= 7 * 24 * 3600 else {
                    error = "请先核对长计时的结束时间，再开始下一项。"; requestFinish(current); return
                }
                _ = try store.switchTimer(id: current.id, nextTitle: cleanTitle, nextCategory: category)
            } else {
                _ = try store.startTimer(title: cleanTitle, category: category)
            }
            title = ""; focused = false; notify()
        } catch { self.error = error.localizedDescription }
    }
    private func requestFinish(_ timer: RunningTimer) {
        if Date().timeIntervalSince(timer.start) > 7 * 24 * 3600 { actualEnd = Date(); overdueTimer = timer }
        else { finish(timer.id) }
    }
    private func finish(_ id: UUID, at: Date = Date()) {
        do { _ = try store.finishTimer(id: id, at: at); notify(); overdueTimer = nil; focused = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

