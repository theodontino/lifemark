import SwiftUI
import LifeCore
import LifeStore

/// One destination per kind of content; analysis lives inside 时间 and 账本 rather than in a separate section.
enum LifeSection: Int, CaseIterable, Identifiable {
    case now, time, ledger, inbox, settings
    var id: Int { rawValue }
    var title: String {
        switch self { case .now: return "现在"; case .time: return "时间"; case .ledger: return "账本"; case .inbox: return "待核对"; case .settings: return "设置" }
    }
    var icon: String {
        switch self { case .now: return "stopwatch"; case .time: return "calendar"; case .ledger: return "creditcard"; case .inbox: return "tray"; case .settings: return "slider.horizontal.3" }
    }
}

@MainActor public struct LifeRootView: View {
    private let store: LifeStore
    private let capturePanel: AnyView?
    @State private var section = LifeSection.now
    public init(store: LifeStore, capturePanel: AnyView? = nil) { self.store = store; self.capturePanel = capturePanel }
    private var inboxCount: Int {
        store.transactions.filter { $0.status == .pending }.count + store.timeBlocks.filter { $0.status == .pending }.count
            + store.conflicts.count + store.recordReadIssues.count
    }
    public var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            } detail: {
                NavigationStack { page(section).navigationTitle("人生记录") }
            }.frame(minWidth: 920, minHeight: 660)
            #else
            TabView(selection: $section) {
                ForEach(LifeSection.allCases) { item in
                    NavigationStack { page(item).navigationTitle(item.title) }
                        .tabItem { Label(item.title, systemImage: item.icon) }
                        .tag(item).badge(item == .inbox ? inboxCount : 0)
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LifeRecord.showTimer"))) { _ in section = .now }
        .tint(lifeAccent).environment(\.locale, lifeLocale)
    }

    @ViewBuilder private func page(_ selection: LifeSection) -> some View {
        switch selection {
        case .now: NowView(store: store) { section = $0 }
        case .time: TimeView(store: store)
        case .ledger: LedgerView(store: store)
        case .inbox: InboxView(store: store)
        case .settings: SettingsView(store: store, capturePanel: capturePanel)
        }
    }

    #if os(macOS)
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LifeSection.allCases.filter { $0 != .settings }) { sidebarRow($0) }
            Spacer()
            sidebarRow(.settings)
            Text(store.syncStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
        }.padding(12).frame(maxHeight: .infinity).background(lifeSidebar)
    }
    private func sidebarRow(_ item: LifeSection) -> some View {
        let selected = section == item
        return Button { section = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).frame(width: 20)
                Text(item.title)
                Spacer(minLength: 4)
                if item == .now, !selected, let timer = store.runningTimers.first {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(String(clockText(context.date.timeIntervalSince(timer.start)).prefix(5)))
                            .font(.caption).monospacedDigit().foregroundStyle(lifeAccentText)
                    }.accessibilityLabel("正在计时")
                }
                if item == .inbox, inboxCount > 0 {
                    Text("\(inboxCount)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(lifeBadgeText)
                        .padding(.horizontal, 7).padding(.vertical, 1).background(lifeBadgeFill, in: Capsule())
                        .accessibilityLabel("\(inboxCount) 条待核对")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(selected ? lifeAccentText : Color.primary).fontWeight(selected ? .semibold : .regular)
            .background(selected ? lifeAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    #endif
}
