import SwiftUI
import LifeCore
import LifeStore

@MainActor struct TransactionEditor: View {
    let store: LifeStore
    private let original: LifeCore.Transaction?
    @State private var item: LifeCore.Transaction
    @State private var amount: String
    @State private var error: String?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    init(store: LifeStore, initial: LifeCore.Transaction) {
        self.store = store
        original = store.transactions.contains(where: { $0.id == initial.id }) ? initial : nil
        _item = State(initialValue: initial)
        _amount = State(initialValue: initial.amountCents > 0 ? String(format: "%.2f", Double(initial.amountCents) / 100) : "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("这笔收支") {
                    Picker("类型", selection: $item.kind) { ForEach(TransactionKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                    TextField("金额（人民币）", text: $amount).moneyInput()
                    TextField("商户 / 对方", text: $item.merchant)
                    TextField("支付账户", text: $item.account)
                    Picker("分类", selection: $item.category) {
                        ForEach(Array(Set(expenseCategories + [item.category])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("发生时间", selection: $item.date)
                    TextField("备注", text: $item.note, axis: .vertical).lineLimit(2...5)
                }
                if item.kind == .expense {
                    Section("回头看，这笔钱花得怎样？") {
                        Picker("你的评价", selection: $item.assessment) { ForEach(PurchaseAssessment.allCases, id: \.self) { Text($0.label).tag($0) } }
                        Text("评价只代表你的感受。金额大或次数多，不直接等于没必要。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if item.kind == .refund {
                    Section("关联原消费") {
                        Picker("原消费（可选）", selection: $item.originalTransactionID) {
                            Text("暂不关联").tag(UUID?.none)
                            ForEach(store.transactions.filter{$0.kind == .expense}.sorted{$0.date > $1.date}.prefix(100).map{$0}) { t in
                                Text("\(t.merchant) · \(Money.format(t.amountCents))").tag(Optional(t.id))
                            }
                        }
                        Text("退款在退款发生的账期冲减消费，不当作工资收入。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if item.kind == .transfer {
                    Section { Text("包括信用卡还款、提现和账户之间转钱。只保留流水，不重复计入消费。请在备注里写清转入账户。").font(.callout).foregroundStyle(.secondary) }
                }
                Section {
                    Label("来源：\(item.source.label)", systemImage: "doc.text")
                    if let fingerprint = item.fingerprint, store.transactions.contains(where: {$0.id != item.id && $0.fingerprint == fingerprint}) {
                        Label("相同图片已导入过，请核对是否重复。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ErrorText(text: error)
                    Button(item.status == .pending ? "核对完成，正式入账" : "保存") { save(confirmed: true) }.buttonStyle(.borderedProminent)
                    if item.status == .pending { Button("先保存为待核对") { save(confirmed: false) } }
                    if store.transactions.contains(where: {$0.id == item.id}) {
                        Button("删除这条记录", role: .destructive) { deleting = true }
                    }
                }
            }.formStyle(.grouped).navigationTitle(item.status == .pending ? "核对收支" : "记录收支")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .confirmationDialog("删除这条记录？", isPresented: $deleting) {
                    Button("删除", role: .destructive) { do { try store.deleteTransaction(id: item.id, ifUnchangedFrom: original ?? item); dismiss() } catch { self.error = error.localizedDescription } }
                }
        }.frame(idealWidth: 540, idealHeight: 680)
    }
    private func save(confirmed: Bool) {
        guard let cents = Money.parseCents(amount), cents > 0 else { error = "请填写大于0、最多两位小数的金额。"; return }
        guard !item.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.account.trimmingCharacters(in: .whitespacesAndNewlines) != "待确认账户" else { error = "请填写账户，例如微信、支付宝或信用卡。"; return }
        item.amountCents = cents; item.currency = "CNY"; item.status = confirmed ? .confirmed : .pending
        do { try store.save(item, ifUnchangedFrom: original); dismiss() } catch { self.error = error.localizedDescription }
    }
}

@MainActor struct TimeEditor: View {
    let store: LifeStore
    private let original: TimeBlock?
    @State private var item: TimeBlock
    @State private var error: String?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    init(store: LifeStore, initial: TimeBlock) { self.store = store; original = store.timeBlocks.contains(where: { $0.id == initial.id }) ? initial : nil; _item = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form {
                Section("实际做过的事情") {
                    TextField("事项名称，例如：备课", text: $item.title)
                    Picker("类别", selection: $item.category) {
                        ForEach(Array(Set(timeCategories + [item.category])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("开始", selection: $item.start)
                    DatePicker("结束", selection: $item.end)
                    TextField("备注", text: $item.note, axis: .vertical).lineLimit(2...5)
                    if item.end > item.start { Text("持续 \(durationText(item.end.timeIntervalSince(item.start)))").foregroundStyle(lifeAccent) }
                }
                Section {
                    Text("同时发生的事项可以重叠保存。同类事情尽量使用相同名称，方便统计通常需要多久。").font(.callout).foregroundStyle(.secondary)
                    Label("来源：\(item.source.label)", systemImage: "doc.text")
                    if !item.evidence.isEmpty {
                        DisclosureGroup("查看自动记录依据") { Text(item.evidence).font(.caption).textSelection(.enabled) }
                    }
                    ErrorText(text: error)
                    Button(item.status == .pending ? "核对完成，确认事项" : "保存实际记录") { save(confirmed: true) }.buttonStyle(.borderedProminent)
                    if item.status == .pending { Button("先保存为待核对") { save(confirmed: false) } }
                    if store.timeBlocks.contains(where: {$0.id == item.id}) { Button("删除", role: .destructive) { deleting = true } }
                }
            }.formStyle(.grouped).navigationTitle("实际时间")
             .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
             .confirmationDialog("删除这条记录？", isPresented: $deleting) {
                 Button("删除", role: .destructive) { do { try store.deleteTimeBlock(id: item.id, ifUnchangedFrom: original ?? item); dismiss() } catch { self.error = error.localizedDescription } }
             }
        }.frame(idealWidth: 540, idealHeight: 650)
    }
    private func save(confirmed: Bool) {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写做过什么。"; return }
        guard item.end > item.start else { error = "结束时间需要晚于开始时间。"; return }
        guard item.end <= Date().addingTimeInterval(300) else { error = "这里只记录实际发生的事情，结束时间不能在未来。"; return }
        item.status = confirmed ? .confirmed : .pending
        do { try store.save(item, ifUnchangedFrom: original); dismiss() } catch { self.error = error.localizedDescription }
    }
}
