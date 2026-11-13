import SwiftUI
import Charts
import LifeCore
import LifeStore

/// Money records and their review share one page: 明细 lists entries, 分析 compares months and merchants.
@MainActor struct LedgerView: View {
    let store: LifeStore
    @State private var selectedDate = Date()
    @State private var mode = 0
    @State private var search = ""
    @State private var editing: LifeCore.Transaction?
    @State private var receipt = false
    @AppStorage("life.billingDay") private var billingDay = 1
    private var period: DateInterval { Analytics.billingPeriod(containing: selectedDate, startDay: billingDay) }
    private var rows: [LifeCore.Transaction] {
        store.transactions.filter { item in
            item.date >= period.start && item.date < period.end
                && (search.isEmpty || [item.merchant, item.category, item.account, item.note].contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.date > $1.date }
    }
    private var confirmedExpenses: [LifeCore.Transaction] {
        store.transactions.filter { $0.status == .confirmed && $0.kind == .expense && $0.currency == "CNY" && $0.date >= period.start && $0.date < period.end }
    }

    var body: some View {
        let total = Analytics.finance(store.transactions, in: period)
        PageScroll {
            PageHeader("账本") {
                Picker("视图", selection: $mode) { Text("明细").tag(0); Text("分析").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().frame(minHeight: controlHeight)
                PeriodNav(label: periodLabel(period), previousLabel: "上一账期", nextLabel: "下一账期",
                          previous: { selectedDate = period.start.addingTimeInterval(-86400) },
                          next: { selectedDate = period.end.addingTimeInterval(86400) })
                Button("读截图") { receipt = true }.buttonStyle(.lifeSecondary)
                Button { editing = .init(amountCents: 0, kind: .expense, category: "餐饮", merchant: "", account: "微信") } label: {
                    Label("记一笔", systemImage: "plus")
                }.buttonStyle(.lifePrimary)
            }
            FlowLayout(spacing: 24) {
                BigFigure(value: Money.format(total.netExpenseCents), caption: "本账期净支出")
                Text("消费 \(Money.format(total.expenseCents)) · 退款 \(Money.format(total.refundCents))").monospacedDigit().foregroundStyle(.secondary)
            }
            if mode == 0 {
                TwoColumns { entries } right: { categoryPanel(total); lookBackPanel }
            } else {
                LedgerAnalysis(store: store, period: period, summary: total) { editing = $0 }
            }
        }
        .sheet(item: $editing) { TransactionEditor(store: store, initial: $0) }
        .sheet(isPresented: $receipt) { ReceiptImportView(store: store) }
    }

    // MARK: Entries

    @ViewBuilder private var entries: some View {
        TextField("搜索商户、类别、账户或备注", text: $search).lifeField().accessibilityLabel("搜索账目")
        let groups = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        if groups.isEmpty {
            Panel {
                EmptyRecords(title: search.isEmpty ? "这个账期还没有账目" : "没有找到符合的账目",
                             detail: search.isEmpty ? "记一笔，或读一张付款截图。信用卡还款选“转账 / 还款”。" : "换一个词，或切换到其他账期。", icon: "creditcard")
            }
        }
        ForEach(groups, id: \.key) { day, items in
            Panel {
                HStack {
                    Text(relativeDay(day)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(daySummary(items)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                RowList(items: items, action: { editing = $0 }) { TransactionLine(item: $0) }
            }
        }
    }
    private func daySummary(_ items: [LifeCore.Transaction]) -> String {
        let confirmed = items.filter { $0.status == .confirmed && $0.currency == "CNY" }
        let spent = confirmed.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        let refunded = confirmed.filter { $0.kind == .refund }.reduce(0) { $0 + $1.amountCents }
        return "支出 " + Money.format(spent) + (refunded > 0 ? " · 退款 " + Money.format(refunded) : "")
    }

    // MARK: Side panels

    private func categoryPanel(_ total: FinanceSummary) -> some View {
        let categories = total.categoryExpenses.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let peak = Double(max(categories.first?.value ?? 0, 1))
        return Panel("钱花在哪里") {
            if categories.isEmpty { Text("确认几笔消费后，这里按类别显示。").foregroundStyle(.secondary) }
            ForEach(categories, id: \.key) { entry in
                BarRow(label: entry.key, value: Money.format(entry.value), fraction: Double(entry.value) / peak)
            }
        }
    }
    private var lookBackPanel: some View {
        let regretted = confirmedExpenses.filter { $0.assessment == .regretted }
        let unrated = confirmedExpenses.filter { $0.assessment == .unrated }.count
        let top = ReviewAnalytics.merchants(transactions: store.transactions, period: period).first
        return Panel("值得回看") {
            VStack(spacing: 0) {
                lookBackRow("你标记后悔的消费", "\(regretted.count) 笔 · " + Money.format(regretted.reduce(0) { $0 + $1.amountCents }))
                Rectangle().fill(lifeLine).frame(height: 1)
                if let top, top.count > 1 {
                    lookBackRow("最常去：" + top.merchant, "\(top.count) 笔 · " + Money.format(top.totalCents))
                    Rectangle().fill(lifeLine).frame(height: 1)
                }
                lookBackRow("还没评价的消费", "\(unrated) 笔")
            }
            Button("查看月度对比和商户明细") { mode = 1 }.buttonStyle(.plain).font(.callout).foregroundStyle(lifeAccentText)
        }
    }
    private func lookBackRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).lineLimit(1); Spacer(); Text(value).fontWeight(.semibold).monospacedDigit() }.frame(minHeight: 44)
    }
}

/// Month comparison, per-category averages, merchants, and purchases the user marked as regretted.
@MainActor struct LedgerAnalysis: View {
    let store: LifeStore
    let period: DateInterval
    let summary: FinanceSummary
    let edit: (LifeCore.Transaction) -> Void
    @State private var hypothetical = ""
    @State private var ai = false
    private var months: [MonthlySpending] { ReviewAnalytics.monthly(transactions: store.transactions) }

    var body: some View {
        let average = ReviewAnalytics.recordedMonthAverage(months)
        let recorded = months.filter { $0.transactionCount > 0 }
        VStack(alignment: .leading, spacing: 16) {
            Panel("近六个月") {
                if recorded.isEmpty {
                    Text("还没有可以比较的月份。").foregroundStyle(.secondary)
                } else {
                    Chart(months) { month in
                        BarMark(x: .value("月份", month.id), y: .value("净支出", Double(month.netExpenseCents) / 100))
                            .foregroundStyle(month.transactionCount == 0 ? Color.gray : lifeAccent)
                    }.frame(height: 180)
                    if let amount = average.averageNetExpenseCents {
                        Text("有记录的 \(average.recordedMonthCount) 个月，平均每月净支出 \(Money.format(amount))").fontWeight(.semibold)
                    }
                    Text("没有记录的月份不按零支出计算。").font(.callout).foregroundStyle(.secondary)
                }
            }
            TwoColumns {
                Panel("常去的地方") {
                    let merchants = ReviewAnalytics.merchants(transactions: store.transactions, period: period)
                    if merchants.isEmpty { Text("确认消费后，这里显示商户次数和金额。").foregroundStyle(.secondary) }
                    VStack(spacing: 0) {
                        ForEach(Array(merchants.prefix(10).enumerated()), id: \.element.id) { index, merchant in
                            if index > 0 { Rectangle().fill(lifeLine).frame(height: 1) }
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(merchant.merchant).fontWeight(.semibold).lineLimit(1)
                                    Text("\(merchant.count) 笔 · 平均 \(Money.format(merchant.averageCents))").font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Money.format(merchant.totalCents)).monospacedDigit()
                            }.frame(minHeight: 48)
                        }
                    }
                }
                Panel("你觉得不值的消费") {
                    let regretted = store.transactions.filter { $0.kind == .expense && $0.assessment == .regretted && $0.status == .confirmed && $0.date >= period.start && $0.date < period.end }
                    if regretted.isEmpty { Text("在账目里把评价选成“后悔这笔”，它们会集中显示在这里。").foregroundStyle(.secondary) }
                    else { RowList(items: Array(regretted.prefix(8)), action: edit) { TransactionLine(item: $0, showsDate: true) } }
                }
            } right: {
                Panel("各类每月平均") {
                    let totals = recorded.reduce(into: [String: Int]()) { result, month in
                        for (name, amount) in month.categoryExpenses { result[name, default: 0] += amount }
                    }.sorted { $0.value > $1.value }
                    if totals.isEmpty { Text("记录累积后显示。").foregroundStyle(.secondary) }
                    ForEach(totals, id: \.key) { entry in
                        HStack { Text(entry.key); Spacer(); Text(Money.format(entry.value / max(recorded.count, 1))).monospacedDigit() }
                    }
                }
                Panel("这笔消费有多大？") {
                    TextField("输入一个金额", text: $hypothetical).lifeField().moneyInput()
                    if let cents = Money.parseCents(hypothetical), cents > 0, cents <= 1_000_000_000_000 {
                        if let baseline = average.averageNetExpenseCents, baseline > 0 {
                            Text("约为平均每月净支出的 \(String(format: "%.0f", Double(cents) / Double(baseline) * 100))%").fontWeight(.semibold)
                        }
                        Text("加上它，本账期净支出为 \(Money.format(summary.netExpenseCents + cents))。")
                        Text("只比较已记录的消费规模，不代表负担得起。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Button { ai = true } label: { Label("让 AI 写一份回顾", systemImage: "sparkles") }.buttonStyle(.lifeSecondary)
            }
        }.sheet(isPresented: $ai) { AIReviewView(store: store, period: period) }
    }
}
