import AppKit
import SwiftUI
import Observation
import LifeStore

private func timerClock(_ start: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}
@MainActor struct LifeTimerMenuLabel: View {
    var body: some View {
        if let timer = LifeIntegrationStore.shared?.runningTimers.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("◉ " + String(timer.title.prefix(9)) + " · " + timerClock(timer.start, now: context.date))
                    .monospacedDigit()
            }
        } else { Label("计时", systemImage: "stopwatch") }
    }
}
@MainActor struct LifeTimerMenuContent: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let store = LifeIntegrationStore.shared { LifeQuickTimerControls(store: store) }
            else { Text(LifeIntegrationStore.openingError ?? "记录暂不可用") }
            Divider()
            Toggle("屏幕顶部悬浮条", isOn: Binding(get: { LifeTimerOverlay.shared.enabled }, set: { LifeTimerOverlay.shared.setEnabled($0) }))
            Button("打开计时主界面") { openWindow(id: "life"); NSApp.activate(ignoringOtherApps: true) }
        }.padding(18).frame(width: 340)
    }
}
@MainActor final class LifeQuickTimerDraft: ObservableObject {
    @Published var title = ""
    @Published var category = "工作"
}
@MainActor struct LifeQuickTimerControls: View {
    let store: LifeStore
    @StateObject private var draft: LifeQuickTimerDraft
    @FocusState private var editingTitle: Bool
    @State private var error: String?
    @State private var cancelling: RunningTimer?
    @State private var recovering: RunningTimer?
    private let categories = ["工作", "学习", "创作", "通勤", "生活", "娱乐", "休息", "待分类"]

    init(store: LifeStore, draft: LifeQuickTimerDraft? = nil) {
        self.store = store
        _draft = StateObject(wrappedValue: draft ?? LifeQuickTimerDraft())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.runningTimers) { timer in
                VStack(alignment: .leading, spacing: 6) {
                    Text(timer.title).font(.headline).lineLimit(2)
                    Text(timer.category).font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timerClock(timer.start, now: context.date)).font(.system(.title2, design: .monospaced))
                    }
                    if Date().timeIntervalSince(timer.start) > 7 * 24 * 60 * 60 {
                        Text("这项计时已超过7天。可核对真实结束时间后保存，或放弃本次计时。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("核对结束时间…") { recovering = timer }
                    } else {
                        Button("结束并保存") { finish(timer.id) }
                    }
                    Button("放弃这次计时…", role: .destructive) { cancelling = timer }
                }
            }
            TextField(store.runningTimers.isEmpty ? "现在做什么？" : "下一项做什么？", text: $draft.title)
                .textFieldStyle(.roundedBorder).focused($editingTitle)
                .onSubmit {
                    if store.runningTimers.isEmpty { begin() }
                    else { editingTitle = false }
                }
            Picker("类别", selection: $draft.category) {
                ForEach(categories, id: \.self) { Text($0).tag($0) }
            }
            Button(store.runningTimers.count == 1 ? "结束当前，开始下一项" : "开始计时") { begin() }
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .confirmationDialog("放弃这次未完成的计时？", isPresented: Binding(
            get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }
        ), titleVisibility: .visible) {
            if let timer = cancelling {
                Button("放弃计时，不生成记录", role: .destructive) {
                    do { try store.cancelTimer(id: timer.id); error = nil }
                    catch { self.error = error.localizedDescription }
                    cancelling = nil
                }
            }
            Button("保留计时", role: .cancel) { cancelling = nil }
        } message: {
            Text("只取消这次正在进行的计时，不生成时间记录，也不会删除已经保存的记录。")
        }
        .sheet(item: $recovering) { timer in
            LifeTimerEndRecovery(store: store, timer: timer)
        }
    }
    private func finish(_ id: UUID) {
        do { _ = try store.finishTimer(id: id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func begin() {
        let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            if store.runningTimers.count == 1, let timer = store.runningTimers.first {
                guard Date().timeIntervalSince(timer.start) <= 7 * 24 * 3600 else {
                    recovering = timer
                    error = "请先核对长计时的结束时间，再开始下一项。"
                    return
                }
                _ = try store.switchTimer(id: timer.id, nextTitle: name, nextCategory: draft.category, at: Date())
            } else {
                _ = try store.startTimer(title: name, category: draft.category)
            }
            draft.title = ""; error = nil; editingTitle = false
        } catch { self.error = error.localizedDescription }
    }
}
@MainActor private struct LifeTimerEndRecovery: View {
    let store: LifeStore
    let timer: RunningTimer
    @Environment(\.dismiss) private var dismiss
    @State private var end: Date
    @State private var error: String?
    init(store: LifeStore, timer: RunningTimer) {
        self.store = store; self.timer = timer
        _end = State(initialValue: Date())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核对真实结束时间").font(.headline)
            Text(timer.title)
            Text("开始：\(timer.start.formatted(date: .abbreviated, time: .shortened))")
            Text("请按实际情况核对结束时间。可以保留完整时长，也可以修正到真实结束时刻；保存前不会自动截断计时。")
                .font(.caption).foregroundStyle(.secondary)
            DatePicker("结束", selection: $end,
                       in: timer.start.addingTimeInterval(1)...Date(),
                       displayedComponents: [.date, .hourAndMinute])
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("返回，保留计时") { dismiss() }
                Spacer()
                Button("按所选时间结束并保存") {
                    do { _ = try store.finishTimer(id: timer.id, at: end); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.padding(20).frame(width: 430)
    }
}
private final class TimerFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class LifeTimerOverlay: ObservableObject {
    static let shared = LifeTimerOverlay()
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "life.topTimer.enabled") as? Bool ?? true
    @Published var expanded = false
    private var panel: NSPanel?
    fileprivate let draft = LifeQuickTimerDraft()
    @Published fileprivate var topInset: CGFloat = 0
    private var installed = false
    private var screenObserver: NSObjectProtocol?
    func install() {
        guard !installed else { return }; installed = true
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observe()
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "life.topTimer.enabled"); refresh()
    }
    func toggleExpanded() { expanded.toggle(); refresh() }
    private func observe() {
        withObservationTracking {
            _ = LifeIntegrationStore.shared?.runningTimers
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh(); self?.observe() }
        }
        refresh()
    }
    private func refresh() {
        guard enabled, let store = LifeIntegrationStore.shared, !store.runningTimers.isEmpty,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel?.orderOut(nil); expanded = false; return
        }
        let inset = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        topInset = inset
        let width: CGFloat = expanded ? 360 : 300
        let height: CGFloat = min(screen.frame.height - 80, inset + (expanded ? CGFloat(max(270, 150 + store.runningTimers.count * 115)) : 42))
        if panel == nil {
            let p = TimerFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: LifeTopTimerView(store: store, overlay: self))
            panel = p
        }
        panel?.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        panel?.orderFrontRegardless()
    }
}
@MainActor private struct LifeTopTimerView: View {
    let store: LifeStore
    @ObservedObject var overlay: LifeTimerOverlay
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { overlay.toggleExpanded() } label: {
                HStack {
                    Image(systemName: "stopwatch")
                    if let timer = store.runningTimers.first {
                        Text(timer.title).lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { context in Text(timerClock(timer.start, now: context.date)).monospacedDigit() }
                    }
                    Image(systemName: overlay.expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.font(.system(size: 12, weight: .medium)).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if overlay.expanded { ScrollView { LifeQuickTimerControls(store: store, draft: overlay.draft).font(.callout) } }
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, overlay.topInset + 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white).tint(.orange)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
        .environment(\.colorScheme, .dark).environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

