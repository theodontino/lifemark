import SwiftUI
import Charts
import LifeCore
import LifeStore

@MainActor struct ReviewsView: View {
    let store: LifeStore
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("回顾内容", selection: $selection) {
                Text("消费回顾").tag(0); Text("时间回顾").tag(1); Text("待核对").tag(2)
            }.pickerStyle(.segmented).padding()
            switch selection {
            case 1: TimeReviewView(store: store)
            case 2: InboxView(store: store)
            default: FinanceReviewView(store: store)
            }
        }.navigationTitle("回顾与分析")
    }
}
@MainActor struct FinanceReviewView: View {
    let store: LifeStore
    @State private var date = Date()
    @State private var hypothetical = ""
    @State private var edited: LifeCore.Transaction?
    @State private var ai = false
    @AppStorage("life.billingDay") private var billingDay = 1
    private var period: DateInterval { Analytics.billingPeriod(containing: date, startDay: billingDay) }
    private var summary: FinanceSummary { Analytics.finance(store.transactions, in: period) }
    private var months: [MonthlySpending] { ReviewAnalytics.monthly(transactions: store.transactions) }
    private var average: RecordedMonthAverage { ReviewAnalytics.recordedMonthAverage(months) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { DatePicker("账期", selection: $date, displayedComponents: .date).labelsHidden(); Spacer(); Text(periodLabel(period)).foregroundStyle(.secondary) }
                Panel("钱花在哪里") {
                    let categories = summary.categoryExpenses.filter{$0.value > 0}.sorted{$0.value > $1.value}
                    if categories.isEmpty { EmptyRecords(title: "还没有足够的消费记录", detail: "确认几笔账目后，这里会按类别展示。", icon: "chart.bar") }
                    else {
                        Chart(categories, id: \.key) { entry in
                            BarMark(x: .value("支出", Double(entry.value)/100), y: .value("类别", entry.key)).foregroundStyle(lifeAccent)
                        }.frame(height: CGFloat(max(150, categories.count * 35)))
                        ForEach(categories, id: \.key) { entry in HStack { Text(entry.key); Spacer(); Text(Money.format(entry.value)).monospacedDigit() }.font(.callout) }
                    }
                    Text("退款按退款发生时间抵扣；转账和信用卡还款不计消费。目前统计人民币记录。").font(.caption).foregroundStyle(.secondary)
                }
                Panel("近六个月，每月都去了哪里") {
                    Chart(months) { month in
                        BarMark(x: .value("月份", month.id), y: .value("净支出", Double(month.netExpenseCents)/100))
                            .foregroundStyle(month.transactionCount == 0 ? .gray : lifeAccent)
                    }.frame(height: 180)
                    if let amount = average.averageNetExpenseCents {
                        Text("有记录月份的平均净支出：\(Money.format(amount))").font(.headline)
                        Text("依据 \(average.recordedMonthCount) 个有记录月份，包含本月；不代表这些月份的账目已经完整。缺记录月份不按零支出计算。").font(.caption).foregroundStyle(.secondary)
                    } else { Text("还没有可计算平均值的月份。").foregroundStyle(.secondary) }
                }
                Panel("有记录月份里，各类平均花多少") {
                    let recorded = months.filter { $0.transactionCount > 0 }
                    let categories = recorded.reduce(into: [String: Int]()) { result, month in
                        for (name, amount) in month.categoryExpenses { result[name, default: 0] += amount }
                    }.sorted { $0.value > $1.value }
                    if recorded.isEmpty { Text("记录累积后显示类别月均。").foregroundStyle(.secondary) }
                    else {
                        ForEach(categories, id: \.key) { entry in
                            HStack { Text(entry.key); Spacer(); Text(Money.format(entry.value / recorded.count)).monospacedDigit() }
                        }
                        Text("每一类都按同样的 \(recorded.count) 个有记录月份平均，包含本月；不能把未记全的月份当完整账目。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Panel("哪些地方出现得频繁") {
                    let merchants = ReviewAnalytics.merchants(transactions: store.transactions, period: period)
                    if merchants.isEmpty { Text("消费确认后，会显示商户次数和累计金额。").foregroundStyle(.secondary) }
                    ForEach(merchants.prefix(10)) { m in
                        HStack { VStack(alignment: .leading) { Text(m.merchant).fontWeight(.medium); Text("\(m.count) 笔 · 平均 \(Money.format(m.averageCents))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(Money.format(m.totalCents)).monospacedDigit() }
                    }
                    let expenses = store.transactions.filter { $0.status == .confirmed && $0.kind == .expense && $0.currency == "CNY" && $0.date >= period.start && $0.date < period.end }
                    let counts = Dictionary(grouping: expenses, by: \.category).sorted { $0.value.count > $1.value.count }
                    if !counts.isEmpty {
                        Divider()
                        Text("按类别看次数").font(.subheadline.bold())
                        ForEach(counts.prefix(8), id: \.key) { entry in
                            HStack { Text(entry.key); Spacer(); Text("\(entry.value.count) 笔").foregroundStyle(.secondary) }
                        }
                    }
                    Text("次数多是回看的线索，不直接判断为浪费；商户名称不同的记录暂不自动合并。").font(.caption).foregroundStyle(.secondary)
                }
                Panel("这笔消费，会有多大？") {
                    TextField("输入想比较的消费金额", text: $hypothetical).moneyInput().textFieldStyle(.roundedBorder)
                    if let cents = Money.parseCents(hypothetical), cents > 0, cents <= 1_000_000_000_000 {
                        if let baseline = average.averageNetExpenseCents, baseline > 0 {
                            Text("约为有记录月份平均净支出的 \(String(format: "%.0f", Double(cents)/Double(baseline)*100))%。").font(.headline)
                        }
                        Text("加上这笔，本账期已记录的净支出将为 \(Money.format(summary.netExpenseCents + cents))。")
                        Text("这是消费规模比较。尚未纳入完整收入、资产及待还款，不能据此认定一定负担得起。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Panel("你自己觉得不值得的消费") {
                    let regretted = store.transactions.filter{$0.kind == .expense && $0.assessment == .regretted && $0.status == .confirmed && $0.date >= period.start && $0.date < period.end}
                    Text("已标记 \(regretted.count) 笔 · \(Money.format(ReviewAnalytics.regrettedSpending(transactions: store.transactions, period: period)))").font(.headline)
                    if regretted.isEmpty { Text("在账目详情中选“后悔这笔”，这里会帮你把它们放在一起回看。").foregroundStyle(.secondary) }
                    ForEach(regretted.prefix(8)) { t in Button { edited = t } label: { TransactionLine(item: t) }.buttonStyle(.plain) }
                }
                Button { ai = true } label: { Label("让 AI 根据这些记录做回顾", systemImage: "sparkles") }.buttonStyle(.bordered)
            }.padding(24).frame(maxWidth: 1100)
        }.sheet(item: $edited) { TransactionEditor(store: store, initial: $0) }
         .sheet(isPresented: $ai) { AIReviewView(store: store, period: period) }
    }
}
@MainActor struct TimeReviewView: View {
    let store: LifeStore
    @State private var date = Date()
    @State private var range = 0
    private var period: DateInterval {
        if range == 1 { return Calendar.current.dateInterval(of: .weekOfYear, for: date)! }
        if range == 2 { return Calendar.current.dateInterval(of: .month, for: date)! }
        return dayInterval(date)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    DatePicker("日期", selection: $date, displayedComponents: .date).labelsHidden()
                    Picker("范围", selection: $range) { Text("当天").tag(0); Text("当周").tag(1); Text("当月").tag(2) }.pickerStyle(.segmented)
                }
                let summary = Analytics.time(store.timeBlocks, in: period)
                Panel("时间主要去了哪里") {
                    HStack { Metric(title: "记录覆盖", value: durationText(summary.occupiedSeconds)); Metric(title: "事项合计", value: durationText(summary.summedSeconds)) }
                    let values = summary.categorySeconds.sorted{$0.value > $1.value}
                    if values.isEmpty { EmptyRecords(title: "先记下做过的事情", detail: "补记或确认自动线索后，就能看到各类事情用了多久。", icon: "clock") }
                    else {
                        Chart(values, id: \.key) { item in
                            BarMark(x: .value("分钟", item.value / 60), y: .value("类别", item.key)).foregroundStyle(lifeAccent)
                        }.frame(height: CGFloat(max(150, values.count*35)))
                    }
                    Text("类别时长保留并行事项，因此可能超过记录覆盖时间。未知时段没有被推定为休息。").font(.caption).foregroundStyle(.secondary)
                }
                Panel("同一件事，通常要多久") {
                    let tasks = ReviewAnalytics.taskDurations(blocks: store.timeBlocks, period: period)
                    if tasks.isEmpty { Text("相同名称的事项会放在一起统计。").foregroundStyle(.secondary) }
                    ForEach(tasks) { t in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(t.title).fontWeight(.medium); Spacer(); Text("\(t.count) 次").foregroundStyle(.secondary) }
                            Text("平均 \(durationText(t.averageSeconds)) · 中位数 \(durationText(t.medianSeconds)) · 合计 \(durationText(t.totalSeconds))").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    Text("只依据这段日期内已确认的记录；跨边界事项按所选范围内的时长统计。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: 1100)
        }
    }
}
@MainActor struct InboxView: View {
    let store: LifeStore
    @State private var transaction: LifeCore.Transaction?
    @State private var block: TimeBlock?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("先核对，再进入正式回顾").font(.title2.bold())
                Text("自动识别只提供线索。标题、分类、金额和时间都可以改。").foregroundStyle(.secondary)
                if !store.conflicts.isEmpty {
                    Panel("同一记录的不同修改") {
                        ForEach(store.conflicts) { conflict in
                            Text("记录 \(conflict.entityID.uuidString.prefix(8)) · 请选择要保留的版本").font(.headline)
                            ForEach(conflict.versions) { version in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(version.label)
                                    DisclosureGroup("版本内容") { Text(version.payload).font(.caption).textSelection(.enabled) }
                                    Button("保留这个版本") { do { try store.resolveConflict(entityID: conflict.entityID, choosing: version.id) } catch { self.error = error.localizedDescription } }
                                }.padding(.vertical, 7)
                            }
                            Divider()
                        }
                    }
                }
                let transactions = store.transactions.filter{$0.status == .pending}
                let blocks = store.timeBlocks.filter{$0.status == .pending}
                if transactions.isEmpty && blocks.isEmpty && store.conflicts.isEmpty {
                    Panel("") { EmptyRecords(title: "待核对区已经清空", detail: "新的截图或自动线索会出现在这里。", icon: "checkmark.circle") }
                }
                if !transactions.isEmpty { Panel("收支草稿") { ForEach(transactions) { t in Button { transaction = t } label: { TransactionLine(item: t) }.buttonStyle(.plain); Divider() } } }
                if !blocks.isEmpty { Panel("时间线索") { ForEach(blocks) { b in Button { block = b } label: { TimeLine(block: b) }.buttonStyle(.plain); Divider() } } }
                ErrorText(text: error)
            }.padding(24).frame(maxWidth: 1100)
        }.sheet(item: $transaction) { TransactionEditor(store: store, initial: $0) }
         .sheet(item: $block) { TimeEditor(store: store, initial: $0) }
    }
}
