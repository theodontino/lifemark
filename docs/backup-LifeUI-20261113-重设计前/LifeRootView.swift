import SwiftUI
import LifeCore
import LifeStore

@MainActor public struct LifeRootView: View {
    private let store: LifeStore
    private let capturePanel: AnyView?
    @State private var destination = 0
    public init(store: LifeStore, capturePanel: AnyView? = nil) { self.store = store; self.capturePanel = capturePanel }
    public var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                List(selection: $destination) {
                    Label("计时与记录", systemImage: "stopwatch").tag(0)
                    Label("账本", systemImage: "creditcard").tag(1)
                    Label("实际时间", systemImage: "clock").tag(2)
                    Label("回顾与分析", systemImage: "chart.bar.xaxis").tag(3)
                    Label("设置与数据", systemImage: "slider.horizontal.3").tag(4)
                }.navigationTitle("人生记录")
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("先记录，再看清", systemImage: "leaf").font(.caption).foregroundStyle(lifeAccent)
                        Text(store.syncStatus).font(.caption2).foregroundStyle(.secondary)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }
            } detail: { NavigationStack { page(destination) } }
            .frame(minWidth: 920, minHeight: 660)
            #else
            TabView(selection: $destination) {
                NavigationStack { page(0) }.tabItem { Label("计时", systemImage: "stopwatch") }.tag(0)
                NavigationStack { page(1) }.tabItem { Label("账本", systemImage: "creditcard") }.tag(1)
                NavigationStack { page(2) }.tabItem { Label("时间", systemImage: "clock") }.tag(2)
                NavigationStack { page(3) }.tabItem { Label("回顾", systemImage: "chart.bar.xaxis") }.tag(3)
                NavigationStack { page(4) }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(4)
            }
            #endif
        }.onReceive(NotificationCenter.default.publisher(for: Notification.Name("LifeRecord.showTimer"))) { _ in destination = 0 }.tint(lifeAccent).environment(\.locale, Locale(identifier: "zh_CN"))
    }
    @ViewBuilder private func page(_ selection: Int) -> some View {
        switch selection {
        case 1: LedgerView(store: store)
        case 2: ActualTimeView(store: store)
        case 3: ReviewsView(store: store)
        case 4: SettingsView(store: store, capturePanel: capturePanel)
        default: TodayView(store: store)
        }
    }
}

@MainActor struct TodayView: View {
    let store: LifeStore
    @State private var transaction: LifeCore.Transaction?
    @State private var block: TimeBlock?
    @State private var receipt = false
    @AppStorage("life.billingDay") private var billingDay = 1
    private var today: DateInterval { dayInterval(Date()) }
    private var finance: FinanceSummary { Analytics.finance(store.transactions, in: Analytics.billingPeriod(containing: Date(), startDay: billingDay)) }
    private var time: TimeSummary { Analytics.time(store.timeBlocks, in: today) }
    private var pending: Int { store.transactions.filter{$0.status == .pending}.count + store.timeBlocks.filter{$0.status == .pending}.count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Date().formatted(.dateTime.month(.wide).day().weekday(.wide))).font(.subheadline).foregroundStyle(.secondary)
                    Text("专心做，结束时记下来。").font(.largeTitle.bold())
                    Text("写下正在做的事，开始计时。一天的回顾会自然累积。").foregroundStyle(.secondary)
                }.padding(.top, 8)
                TimerPanel(store: store)
                Panel("") {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) { metrics }
                        VStack(alignment: .leading, spacing: 18) { metrics }
                    }
                }
                HStack {
                    Button { transaction = .init(amountCents: 0, kind: .expense, category: "餐饮", merchant: "", account: "微信") } label: { Label("记一笔", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Button { receipt = true } label: { Label("读截图", systemImage: "doc.viewfinder") }.buttonStyle(.bordered)
                    Button { block = .init(title: "", category: "工作", start: Date().addingTimeInterval(-1800), end: Date()) } label: { Label("补记时间", systemImage: "clock.badge.plus") }.buttonStyle(.bordered)
                }.controlSize(.large)
                if !store.conflicts.isEmpty {
                    Label("有 \(store.conflicts.count) 项修改冲突，暂未计入统计。请到“回顾 → 待核对”选择保留的版本。", systemImage: "arrow.triangle.branch")
                        .font(.callout).foregroundStyle(.orange)
                }
                Panel("今天的实际记录") {
                    let rows = store.timeBlocks.filter { $0.start < today.end && $0.end > today.start }.sorted{$0.start < $1.start}
                    if rows.isEmpty { EmptyRecords(title: "从一小段实际经历开始", detail: "补记刚才做了什么。自动采集的线索会先进入待核对区。", icon: "clock") }
                    else { ForEach(rows) { item in Button { block = item } label: { TimeLine(block: item) }.buttonStyle(.plain); Divider() } }
                }
                Panel("今天记下的收支") {
                    let rows = store.transactions.filter{$0.date >= today.start && $0.date < today.end}.sorted{$0.date > $1.date}
                    if rows.isEmpty { Text("还没有记录。选一张付款截图，或手工记一笔。").foregroundStyle(.secondary) }
                    else { ForEach(rows) { item in Button { transaction = item } label: { TransactionLine(item: item) }.buttonStyle(.plain); Divider() } }
                }
                Text("统计反映已确认的记录；没有记录的时间仍是未知。").font(.caption).foregroundStyle(.secondary)
                ErrorText(text: store.errorMessage)
            }.padding(24).frame(maxWidth: 1100)
        }.navigationTitle("计时与记录")
         .sheet(item: $transaction) { TransactionEditor(store: store, initial: $0) }
         .sheet(item: $block) { TimeEditor(store: store, initial: $0) }
         .sheet(isPresented: $receipt) { ReceiptImportView(store: store) }
    }
    @ViewBuilder private var metrics: some View {
        Metric(title: "本账期净支出", value: Money.format(finance.netExpenseCents), caption: "退款已抵扣 · 转账不计消费")
        Metric(title: "今天已记录覆盖", value: durationText(time.occupiedSeconds), caption: "重叠时段只计算一次")
        Metric(title: "待核对", value: "\(pending) 条", caption: "核对后进入正式统计")
    }
}

@MainActor struct LedgerView: View {
    let store: LifeStore
    @State private var selectedDate = Date()
    @State private var search = ""
    @State private var editing: LifeCore.Transaction?
    @State private var receipt = false
    @AppStorage("life.billingDay") private var billingDay = 1
    private var period: DateInterval { Analytics.billingPeriod(containing: selectedDate, startDay: billingDay) }
    private var rows: [LifeCore.Transaction] {
        store.transactions.filter { $0.date >= period.start && $0.date < period.end && (search.isEmpty || [$0.merchant,$0.category,$0.account,$0.note].contains{$0.localizedCaseInsensitiveContains(search)}) }.sorted{$0.date > $1.date}
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    DatePicker("查看账期", selection: $selectedDate, displayedComponents: .date).labelsHidden()
                    Spacer()
                    Button { receipt = true } label: { Label("读截图", systemImage: "doc.viewfinder") }
                    Button { editing = .init(amountCents: 0, kind: .expense, category: "餐饮", merchant: "", account: "微信") } label: { Label("记一笔", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                Text(periodLabel(period)).font(.title2.bold())
                let total = Analytics.finance(store.transactions, in: period)
                Panel("") { HStack(alignment: .top) { Metric(title: "消费", value: Money.format(total.expenseCents)); Metric(title: "退款", value: Money.format(total.refundCents)); Metric(title: "净支出", value: Money.format(total.netExpenseCents)) } }
                TextField("搜索商户、类别、账户或备注", text: $search).textFieldStyle(.roundedBorder)
                Panel("账目明细 · \(rows.count) 条") {
                    if rows.isEmpty { EmptyRecords(title: "这个账期还没有账目", detail: "记录消费、退款或转账。信用卡还款应选“转账 / 还款”。", icon: "creditcard") }
                    else { ForEach(rows) { item in Button { editing = item } label: { TransactionLine(item: item) }.buttonStyle(.plain); Divider() } }
                }
            }.padding(24).frame(maxWidth: 1100)
        }.navigationTitle("账本")
         .sheet(item: $editing) { TransactionEditor(store: store, initial: $0) }
         .sheet(isPresented: $receipt) { ReceiptImportView(store: store) }
    }
}

@MainActor struct ActualTimeView: View {
    let store: LifeStore
    @State private var day = Date()
    @State private var editing: TimeBlock?
    private var period: DateInterval { dayInterval(day) }
    private var rows: [TimeBlock] { store.timeBlocks.filter{$0.start < period.end && $0.end > period.start}.sorted{$0.start < $1.start} }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    DatePicker("日期", selection: $day, displayedComponents: .date).labelsHidden()
                    Spacer()
                    Button { editing = .init(title: "", category: "工作", start: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!, end: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day)!) } label: { Label("补记实际时间", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                let summary = Analytics.time(store.timeBlocks, in: period)
                Panel("") {
                    HStack(alignment: .top) {
                        Metric(title: "记录覆盖", value: durationText(summary.occupiedSeconds))
                        Metric(title: "各事项合计", value: durationText(summary.summedSeconds))
                        Metric(title: "同时进行", value: durationText(summary.overlapSeconds))
                    }
                    Text("可以同时通勤和听课。各事项保留完整时长，覆盖时间按重叠去重。").font(.caption).foregroundStyle(.secondary)
                }
                if rows.isEmpty { Panel("") { EmptyRecords(title: "这一天等待被补全", detail: "记录做过的事，不把空白时段当作休息或浪费。", icon: "calendar") } }
                else {
                    Panel("并行时间线") { ParallelTimeline(blocks: rows.filter{$0.status == .confirmed}, period: period) }
                    Panel("全部事项") { ForEach(rows) { item in Button { editing = item } label: { TimeLine(block: item) }.buttonStyle(.plain); Divider() } }
                }
            }.padding(24).frame(maxWidth: 1100)
        }.navigationTitle("实际时间").sheet(item: $editing) { TimeEditor(store: store, initial: $0) }
    }
}
struct ParallelTimeline: View {
    let blocks: [TimeBlock]; let period: DateInterval
    private var begin: Date { max(period.start, blocks.map(\.start).min() ?? period.start) }
    private var finish: Date { min(period.end, blocks.map(\.end).max() ?? period.end) }
    private var range: Double { max(60, finish.timeIntervalSince(begin)) }
    private func top(_ block: TimeBlock) -> Double { max(0, max(block.start, begin).timeIntervalSince(begin) / range * 280) }
    private func height(_ block: TimeBlock) -> Double { max(24, min(block.end, finish).timeIntervalSince(max(block.start, begin)) / range * 280) }
    private var columns: [[TimeBlock]] {
        var result: [[TimeBlock]] = []
        for block in blocks.sorted(by: { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }) {
            // Layout uses drawn heights as well as actual intervals, so adjacent short labels do not collide.
            if let lane = result.firstIndex(where: { lane in
                guard let last = lane.last else { return true }
                return last.end <= block.start && top(last) + height(last) + 2 <= top(block)
            }) { result[lane].append(block) }
            else { result.append([block]) }
        }
        return result
    }
    var body: some View {
        if blocks.isEmpty { Text("待核对的线索确认后显示在这里。").foregroundStyle(.secondary) }
        else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    VStack { Text(begin.formatted(.dateTime.hour().minute())); Spacer(); Text(finish.formatted(.dateTime.hour().minute())) }
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 44, height: 280)
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, lane in
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03))
                            ForEach(lane) { block in
                                Text(block.title).font(.caption).lineLimit(1).padding(4)
                                    .frame(width: 150, height: height(block), alignment: .topLeading)
                                    .background(lifeAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                                    .clipped().offset(y: top(block))
                            }
                        }.frame(width: 150, height: 304)
                    }
                }
            }
            Text("短事项按最小可读高度显示，必要时分列；完整起止时间见下方列表。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
