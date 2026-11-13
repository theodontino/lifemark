import SwiftUI
import LifeCore
import LifeStore

/// The running timer is the page's lead element; starting the next task and today's records follow.
@MainActor struct NowView: View {
    let store: LifeStore
    let open: (LifeSection) -> Void
    @State private var title = ""
    @State private var category = "工作"
    @State private var cancelling: RunningTimer?
    @State private var overdueTimer: RunningTimer?
    @State private var actualEnd = Date()
    @State private var error: String?
    @State private var activityStatus = ""
    @State private var transaction: LifeCore.Transaction?
    @State private var block: TimeBlock?
    @State private var receipt = false
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 56

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var today: DateInterval { dayInterval(Date()) }
    private var todayBlocks: [TimeBlock] {
        store.timeBlocks.filter { $0.start < today.end && $0.end > today.start }.sorted { $0.start > $1.start }
    }
    private var recentTasks: [(title: String, category: String)] {
        var seen = Set<String>(store.runningTimers.map(\.title)), result: [(title: String, category: String)] = []
        for item in store.timeBlocks.filter({ $0.status == .confirmed }).sorted(by: { $0.end > $1.end }) where seen.insert(item.title).inserted {
            result.append((title: item.title, category: item.category))
            if result.count == 5 { break }
        }
        return result
    }

    var body: some View {
        PageScroll {
            PageHeader("现在", subtitle: monthDay(Date()) + " " + weekdayText(Date())) {
                Button("读截图") { receipt = true }.buttonStyle(.lifeSecondary)
                Button { transaction = newTransactionDraft() } label: {
                    Label("记一笔", systemImage: "plus")
                }.buttonStyle(.lifeSecondary)
            }
            ForEach(store.runningTimers) { hero($0) }
            nextPanel
            ErrorText(text: error ?? store.errorMessage)
            todaySection
            #if os(iOS)
            if !activityStatus.isEmpty, !store.runningTimers.isEmpty { Text(activityStatus).font(.footnote).foregroundStyle(.secondary) }
            #endif
        }
        .sheet(item: $transaction) { TransactionEditor(store: store, initial: $0) }
        .sheet(item: $block) { TimeEditor(store: store, initial: $0) }
        .sheet(isPresented: $receipt) { ReceiptImportView(store: store) }
        .sheet(item: $overdueTimer) { overdueSheet($0) }
        .confirmationDialog("放弃这次计时？", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                            titleVisibility: .visible, presenting: cancelling) { timer in
            Button("放弃，不保存记录", role: .destructive) {
                do { try store.cancelTimer(id: timer.id); notify(); error = nil } catch { self.error = error.localizedDescription }
            }
        } message: { timer in Text("“\(timer.title)”不会生成时间记录。") }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LifeRecord.timerActivityStatus"))) { note in
            activityStatus = note.userInfo?["status"] as? String ?? ""
        }
    }

    // MARK: Running timer

    private func hero(_ timer: RunningTimer) -> some View {
        let sameDay = Calendar.current.isDateInToday(timer.start)
        let info = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(lifeAccentText).frame(width: 9, height: 9)
                Text("正在计时").font(.callout).foregroundStyle(lifeAccentText)
                Tag(text: timer.category, color: lifeAccentText)
            }
            Text(timer.title).font(.title2.bold()).lineLimit(2)
            Text((sameDay ? "" : monthDay(timer.start) + " ") + hourMinute(timer.start) + " 开始").font(.callout).foregroundStyle(.secondary)
        }
        let clock = TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(clockText(context.date.timeIntervalSince(timer.start)))
                .font(.system(size: clockSize, weight: .semibold)).monospacedDigit()
                .foregroundStyle(lifeAccentText).lineLimit(1).minimumScaleFactor(0.5)
        }
        let finish = Button { requestFinish(timer) } label: { Text("结束并保存").frame(maxWidth: .infinity) }.buttonStyle(.lifePrimary)
        let cancel = Button { cancelling = timer } label: { Text("放弃这次计时").frame(maxWidth: .infinity) }
            .buttonStyle(LifeButtonStyle(kind: .onAccentSoft))
        return Group {
            #if os(macOS)
            HStack(alignment: .center, spacing: 24) {
                info.frame(maxWidth: .infinity, alignment: .leading)
                clock
                VStack(spacing: 8) { finish; cancel }.frame(width: 150)
            }
            #else
            VStack(alignment: .leading, spacing: 12) {
                info
                clock
                HStack(spacing: 10) { finish; cancel }
            }
            #endif
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .background(lifeAccentSoft, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(lifeAccentLine, lineWidth: 1))
    }

    // MARK: Next task

    private var nextPanel: some View {
        let running = store.runningTimers.count
        return Panel {
            Text(running == 0 ? "现在做什么？" : "接下来做什么？").font(.headline)
            FlowLayout(spacing: 10) {
                TextField("例如：备课、读书、处理消息", text: $title).lifeField().focused($focused)
                    .frame(minWidth: 220, idealWidth: 360)
                    // Return starts only when nothing is running; it never ends a running timer.
                    .onSubmit { if running == 0 { begin(replacing: false) } }
                if running == 0 {
                    Button { begin(replacing: false) } label: { Label("开始计时", systemImage: "play.fill") }.buttonStyle(.lifePrimary).disabled(cleanTitle.isEmpty)
                } else if running == 1 {
                    Button("切换到这一项") { begin(replacing: true) }.buttonStyle(.lifePrimary).disabled(cleanTitle.isEmpty)
                    Button("同时开始") { begin(replacing: false) }.buttonStyle(.lifeSecondary).disabled(cleanTitle.isEmpty)
                } else {
                    Button("同时开始") { begin(replacing: false) }.buttonStyle(.lifePrimary).disabled(cleanTitle.isEmpty)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                FieldLabel("类别")
                ChipPicker(options: timeCategories, selection: $category)
            }
            if !recentTasks.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    FieldLabel("最近")
                    FlowLayout {
                        ForEach(recentTasks, id: \.title) { task in
                            Chip(title: task.title, selected: false) { title = task.title; category = task.category }
                        }
                    }
                }
            }
            if running == 1 { Text("“切换”会结束当前计时并保存；“同时开始”让两项一起计时。").font(.callout).foregroundStyle(.secondary) }
        }
    }

    // MARK: Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("今天").font(.title3.bold())
                Spacer()
                Text("已记录 " + durationText(Analytics.time(store.timeBlocks, in: today).occupiedSeconds)).font(.callout).foregroundStyle(.secondary)
                Button("查看完整时间线") { open(.time) }.buttonStyle(.plain).font(.callout).foregroundStyle(lifeAccentText)
            }
            Panel {
                if todayBlocks.isEmpty {
                    Text("今天还没有记录。开始一个计时，或补记刚才做的事。").foregroundStyle(.secondary)
                } else {
                    RowList(items: todayBlocks, action: { block = $0 }) { TimeLine(block: $0) }
                }
            }
            Button { block = .init(title: "", category: "工作", start: Date().addingTimeInterval(-1800), end: Date()) } label: {
                Label("补记一段时间", systemImage: "plus")
            }.buttonStyle(.lifeSecondary)
        }
    }

    // MARK: Actions

    private func overdueSheet(_ timer: RunningTimer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核对结束时间").font(.title2.bold())
            Text("“\(timer.title)”已经计时超过 7 天。请填写实际结束的时间，避免把忘记结束的时间算进去。").foregroundStyle(.secondary)
            DatePicker("实际结束", selection: $actualEnd, in: timer.start...Date())
            ErrorText(text: error)
            HStack {
                Spacer()
                Button("取消") { overdueTimer = nil }.buttonStyle(.lifeSecondary).keyboardShortcut(.cancelAction)
                Button("结束并保存") { finish(timer.id, at: actualEnd) }.buttonStyle(.lifePrimary).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 320, idealWidth: 440).environment(\.locale, lifeLocale).tint(lifeAccent)
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
        do { _ = try store.finishTimer(id: id, at: at); notify(); overdueTimer = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
