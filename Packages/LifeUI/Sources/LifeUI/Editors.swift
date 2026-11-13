import SwiftUI
import LifeCore
import LifeStore

/// Shared frame for the editing sheets: scrolling fields, and a bottom bar with delete on the left
/// and cancel / save together on the right.
struct EditorSheet<Fields: View, Actions: View>: View {
    let title: String
    let error: String?
    let onDelete: (() -> Void)?
    private let fields: Fields, actions: Actions
    @Environment(\.dismiss) private var dismiss
    init(title: String, error: String?, onDelete: (() -> Void)?, @ViewBuilder fields: () -> Fields, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.error = error; self.onDelete = onDelete; self.fields = fields(); self.actions = actions()
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title).font(.title2.bold())
                    fields
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(lifeLine).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                ErrorText(text: error)
                FlowLayout(spacing: 10) {
                    if let onDelete { Button("删除", role: .destructive, action: onDelete).buttonStyle(.lifeDanger) }
                    Button("取消") { dismiss() }.buttonStyle(.lifeSecondary).keyboardShortcut(.cancelAction)
                    actions
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .background(lifeSurface).tint(lifeAccent).environment(\.locale, lifeLocale)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
    }
}
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 6) { FieldLabel(label); content } }
}

@MainActor struct TransactionEditor: View {
    let store: LifeStore
    private let original: LifeCore.Transaction?
    @State private var item: LifeCore.Transaction
    @State private var amount: String
    @State private var error: String?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 32
    init(store: LifeStore, initial: LifeCore.Transaction) {
        self.store = store
        original = store.transactions.contains(where: { $0.id == initial.id }) ? initial : nil
        _item = State(initialValue: initial)
        _amount = State(initialValue: initial.amountCents > 0 ? String(format: "%.2f", Double(initial.amountCents) / 100) : "")
    }
    private var accounts: [String] {
        var seen = Set<String>(), result: [String] = []
        let used = store.transactions.sorted { $0.date > $1.date }.map { $0.account.trimmingCharacters(in: .whitespacesAndNewlines) }
        for name in ["微信", "支付宝", "信用卡"] + used where !name.isEmpty && name != "待确认账户" && name != "默认账户" && seen.insert(name).inserted {
            result.append(name)
            if result.count == 6 { break }
        }
        return result
    }
    private var title: String { item.status == .pending ? "核对这一笔" : (original == nil ? "记一笔" : "修改这一笔") }

    var body: some View {
        EditorSheet(title: title, error: error, onDelete: original == nil ? nil : { deleting = true }) {
            Picker("类型", selection: $item.kind) { ForEach(TransactionKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            LabeledField(label: "金额（人民币）") {
                HStack(spacing: 8) {
                    Text("¥").font(.system(size: amountSize * 0.8)).foregroundStyle(.secondary)
                    TextField("0.00", text: $amount).textFieldStyle(.plain).moneyInput()
                        .font(.system(size: amountSize, weight: .bold)).monospacedDigit().accessibilityLabel("金额")
                }
                .padding(.horizontal, 14).frame(minHeight: amountSize + 28)
                .background(lifeGround, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(lifeAccent, lineWidth: 2))
            }
            LabeledField(label: "商户 / 对方") { TextField("例如：食堂", text: $item.merchant).lifeField() }
            LabeledField(label: "发生时间") { DatePicker("发生时间", selection: $item.date).labelsHidden() }
            LabeledField(label: "支付账户") {
                TextField("例如：微信、招行信用卡", text: $item.account).lifeField()
                FlowLayout { ForEach(accounts, id: \.self) { name in Chip(title: name, selected: item.account == name) { item.account = name } } }
            }
            LabeledField(label: "分类") { ChipPicker(options: expenseCategories, selection: $item.category) }
            LabeledField(label: "备注（可不填）") { TextField("", text: $item.note, axis: .vertical).lineLimit(1...4).lifeField().accessibilityLabel("备注") }
            if item.kind == .transfer {
                Text("包括信用卡还款、提现和账户之间转钱，不计入消费。请在备注里写清转入账户。").font(.callout).foregroundStyle(.secondary)
            }
            if item.kind == .refund {
                LabeledField(label: "关联原消费（可不选）") {
                    Picker("原消费", selection: $item.originalTransactionID) {
                        Text("暂不关联").tag(UUID?.none)
                        ForEach(store.transactions.filter { $0.kind == .expense }.sorted { $0.date > $1.date }.prefix(100).map { $0 }) { t in
                            Text("\(t.merchant) · \(Money.format(t.amountCents))").tag(Optional(t.id))
                        }
                    }.labelsHidden()
                    Text("退款在发生的账期里冲减消费。").font(.callout).foregroundStyle(.secondary)
                }
            }
            // Whether a purchase was worth it is judged when looking back, not while entering it.
            if item.kind == .expense, original != nil {
                LabeledField(label: "回头看，这笔钱花得怎样？") {
                    FlowLayout {
                        ForEach(PurchaseAssessment.allCases, id: \.self) { value in
                            Chip(title: value.label, selected: item.assessment == value) { item.assessment = value }
                        }
                    }
                }
            } else if item.kind == .expense {
                Text("“值不值”可以等回看账本时再评价。").font(.callout).foregroundStyle(.secondary)
            }
            if item.source != .manual { Text("来源：\(item.source.label)").font(.callout).foregroundStyle(.secondary) }
            if let fingerprint = item.fingerprint, store.transactions.contains(where: { $0.id != item.id && $0.fingerprint == fingerprint }) {
                Label("同一张图片已经导入过，请核对是否重复。", systemImage: "exclamationmark.triangle").foregroundStyle(lifeWarnText)
            }
        } actions: {
            if item.status == .pending { Button("先存为草稿") { save(confirmed: false) }.buttonStyle(.lifeSecondary) }
            Button(item.status == .pending ? "核对完成，入账" : "保存") { save(confirmed: true) }.buttonStyle(.lifePrimary).keyboardShortcut(.defaultAction)
        }
        .confirmationDialog("删除这条记录？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try store.deleteTransaction(id: item.id, ifUnchangedFrom: original ?? item); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save(confirmed: Bool) {
        guard let cents = Money.parseCents(amount), cents > 0 else { error = "请填写大于 0、最多两位小数的金额。"; return }
        let account = item.account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, account != "待确认账户" else { error = "请填写账户，例如微信、支付宝或信用卡。"; return }
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
    init(store: LifeStore, initial: TimeBlock) {
        self.store = store
        // Compare by identity: the inbox may hand over a draft whose title was cleared for the user to fill in.
        original = store.timeBlocks.first(where: { $0.id == initial.id })
        _item = State(initialValue: initial)
    }
    private var title: String { item.status == .pending ? "核对这段时间" : (original == nil ? "补记一段时间" : "修改这段时间") }

    var body: some View {
        EditorSheet(title: title, error: error, onDelete: original == nil ? nil : { deleting = true }) {
            LabeledField(label: "做了什么") { TextField("例如：备课", text: $item.title).lifeField() }
            LabeledField(label: "类别") { ChipPicker(options: timeCategories, selection: $item.category) }
            LabeledField(label: "开始") { DatePicker("开始", selection: $item.start).labelsHidden() }
            LabeledField(label: "结束") { DatePicker("结束", selection: $item.end).labelsHidden() }
            if item.end > item.start {
                Text("持续 " + durationText(item.end.timeIntervalSince(item.start))).fontWeight(.semibold).foregroundStyle(lifeAccentText)
            }
            LabeledField(label: "备注（可不填）") { TextField("", text: $item.note, axis: .vertical).lineLimit(1...4).lifeField().accessibilityLabel("备注") }
            if item.source != .manual { Text("来源：\(item.source.label)").font(.callout).foregroundStyle(.secondary) }
            if !item.evidence.isEmpty {
                DisclosureGroup("查看自动记录的依据") { Text(item.evidence).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        } actions: {
            if item.status == .pending { Button("先存为草稿") { save(confirmed: false) }.buttonStyle(.lifeSecondary) }
            Button(item.status == .pending ? "核对完成，确认" : "保存") { save(confirmed: true) }.buttonStyle(.lifePrimary).keyboardShortcut(.defaultAction)
        }
        .confirmationDialog("删除这条记录？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try store.deleteTimeBlock(id: item.id, ifUnchangedFrom: original ?? item); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save(confirmed: Bool) {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写做了什么。"; return }
        guard item.end > item.start else { error = "结束时间需要晚于开始时间。"; return }
        guard item.end <= Date().addingTimeInterval(300) else { error = "这里只记录已经发生的事，结束时间不能在未来。"; return }
        item.status = confirmed ? .confirmed : .pending
        do { try store.save(item, ifUnchangedFrom: original); dismiss() } catch { self.error = error.localizedDescription }
    }
}
