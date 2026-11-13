import SwiftUI
import LifeCore
import LifeStore

/// Everything that needs a decision before it counts: conflicting edits, unreadable records, drafts and clues.
@MainActor struct InboxView: View {
    let store: LifeStore
    @State private var transaction: LifeCore.Transaction?
    @State private var block: TimeBlock?
    @State private var discardingTransaction: LifeCore.Transaction?
    @State private var discardingBlock: TimeBlock?
    @State private var receipt = false
    @State private var namingPlace: TimeBlock?
    @State private var placeName = ""
    @State private var error: String?
    private var drafts: [LifeCore.Transaction] { store.transactions.filter { $0.status == .pending } }
    private var clues: [TimeBlock] { store.timeBlocks.filter { $0.status == .pending } }
    private var count: Int { drafts.count + clues.count + store.conflicts.count + store.recordReadIssues.count }

    var body: some View {
        PageScroll {
            PageHeader("待核对", subtitle: count == 0 ? "" : "\(count) 条。确认之后才计入统计。") {
                Button("读截图") { receipt = true }.buttonStyle(.lifeSecondary)
            }
            ErrorText(text: error)
            if count == 0 {
                Panel { EmptyRecords(title: "没有需要核对的内容", detail: "新的截图草稿和自动线索会出现在这里。", icon: "checkmark.circle") }
            }
            ForEach(store.conflicts) { conflictCard($0) }
            if !store.recordReadIssues.isEmpty {
                warningCard(title: "有 \(store.recordReadIssues.count) 条记录读不出来") {
                    Text("其他记录不受影响，原始数据没有改动。").foregroundStyle(.secondary)
                    ForEach(store.recordReadIssues) { Text($0.message).font(.callout).textSelection(.enabled) }
                }
            }
            if !drafts.isEmpty {
                section("收支草稿 · \(drafts.count)") {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(lifeLine).frame(height: 1) }
                        draftRow(item)
                    }
                }
            }
            if !clues.isEmpty {
                section("时间线索 · \(clues.count)") {
                    ForEach(Array(clues.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(lifeLine).frame(height: 1) }
                        clueRow(item)
                    }
                }
            }
        }
        .sheet(item: $transaction) { TransactionEditor(store: store, initial: $0) }
        .sheet(item: $block) { TimeEditor(store: store, initial: $0) }
        .sheet(isPresented: $receipt) { ReceiptImportView(store: store) }
        .alert("这是哪里？", isPresented: Binding(get: { namingPlace != nil }, set: { if !$0 { namingPlace = nil } }), presenting: namingPlace) { item in
            TextField("例如：家、学校、食堂", text: $placeName)
            Button("取消", role: .cancel) {}
            Button("保存") { run { try store.namePlace(for: item, name: placeName) } }
        } message: { _ in Text("以后在这里的停留会自动带上这个名字。位置只保存在这台手机上。") }
        .confirmationDialog("丢弃这条草稿？", isPresented: Binding(get: { discardingTransaction != nil }, set: { if !$0 { discardingTransaction = nil } }),
                            titleVisibility: .visible, presenting: discardingTransaction) { item in
            Button("丢弃", role: .destructive) { run { try store.deleteTransaction(id: item.id, ifUnchangedFrom: item) } }
        }
        .confirmationDialog("丢弃这条线索？", isPresented: Binding(get: { discardingBlock != nil }, set: { if !$0 { discardingBlock = nil } }),
                            titleVisibility: .visible, presenting: discardingBlock) { item in
            Button("丢弃", role: .destructive) { run { try store.deleteTimeBlock(id: item.id, ifUnchangedFrom: item) } }
        }
    }

    private func run(_ work: () throws -> Void) {
        do { try work(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Panel { VStack(spacing: 0) { content() } }
        }
    }
    private func warningCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(lifeWarnSoft, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(lifeWarnLine, lineWidth: 1))
    }
    private func actionRow<Info: View, Actions: View>(@ViewBuilder info: () -> Info, @ViewBuilder actions: () -> Actions) -> some View {
        #if os(macOS)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) { info() }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions() }
        }.padding(.vertical, 10)
        #else
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) { info() }
            HStack(spacing: 8) { actions() }
        }.padding(.vertical, 12)
        #endif
    }

    // MARK: Drafts and clues

    private func draftRow(_ item: LifeCore.Transaction) -> some View {
        let account = item.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = account.isEmpty || account == "待确认账户" ? "账户还没填" : (item.merchant.isEmpty ? "商户还没填" : "")
        return actionRow {
            Text((item.merchant.isEmpty ? item.category : item.merchant) + "  " + Money.format(item.amountCents)).fontWeight(.semibold).monospacedDigit()
            Text("来自\(item.source.label) · \(account.isEmpty ? "未填账户" : account) · \(monthDay(item.date)) \(hourMinute(item.date))").font(.callout).foregroundStyle(.secondary)
            if !missing.isEmpty { Text(missing).font(.callout).foregroundStyle(lifeWarnText) }
        } actions: {
            Button("丢弃") { discardingTransaction = item }.buttonStyle(.lifeSecondary)
            Button("核对并入账") { transaction = item }.buttonStyle(.lifePrimary)
        }
    }
    private func clueRow(_ item: TimeBlock) -> some View {
        // A location stay says where, not what: it cannot be confirmed without a title from the user.
        let needsTitle = item.source == .location || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let range = "\(relativeDay(item.start)) \(hourMinute(item.start)) – \(hourMinute(item.end))"
        return actionRow {
            if needsTitle { Text("在\(item.place.map { "“\($0)”" } ?? "某处")停留了 " + durationText(item.end.timeIntervalSince(item.start))).fontWeight(.semibold) }
            else { Text(item.title + " · " + item.category).fontWeight(.semibold) }
            Text("来自\(item.source.label) · \(range)").font(.callout).foregroundStyle(.secondary)
        } actions: {
            Button("丢弃") { discardingBlock = item }.buttonStyle(.lifeSecondary)
            #if os(iOS)
            if item.source == .location, item.place == nil {
                Button("给地点起名") { placeName = ""; namingPlace = item }.buttonStyle(.lifeSecondary)
            }
            #endif
            if needsTitle {
                Button("填写当时在做什么") { var draft = item; if item.source == .location { draft.title = "" }; block = draft }.buttonStyle(.lifePrimary)
            } else {
                Button("修改") { block = item }.buttonStyle(.lifeSecondary)
                Button("确认") { var confirmed = item; confirmed.status = .confirmed; run { try store.save(confirmed, ifUnchangedFrom: item) } }.buttonStyle(.lifePrimary)
            }
        }
    }

    // MARK: Conflicts

    private func fields(_ version: RevisionChoice) -> [(name: String, value: String)] {
        if version.isDeleted { return [(name: "操作", value: "删除这条记录")] }
        let data = Data(version.payload.utf8)
        if let item = try? JSONDecoder().decode(LifeCore.Transaction.self, from: data) {
            return [(name: "类型", value: item.kind.label), (name: "金额", value: Money.format(item.amountCents)), (name: "商户", value: item.merchant),
                    (name: "账户", value: item.account), (name: "分类", value: item.category),
                    (name: "时间", value: monthDay(item.date) + " " + hourMinute(item.date)), (name: "评价", value: item.assessment.label), (name: "备注", value: item.note)]
        }
        if let item = try? JSONDecoder().decode(TimeBlock.self, from: data) {
            return [(name: "事项", value: item.title), (name: "类别", value: item.category),
                    (name: "开始", value: monthDay(item.start) + " " + hourMinute(item.start)),
                    (name: "结束", value: monthDay(item.end) + " " + hourMinute(item.end)), (name: "备注", value: item.note)]
        }
        return [(name: "内容", value: "这个版本读不出来")]
    }
    private func conflictCard(_ conflict: RecordConflict) -> some View {
        let versions = conflict.versions.map { (choice: $0, fields: conflict.kind == "timer" ? [(name: "计时结果", value: $0.label)] : fields($0)) }
        var values: [String: Set<String>] = [:]
        for version in versions { for field in version.fields { values[field.name, default: []].insert(field.value) } }
        // A field differs when versions disagree on it, or when only some versions have it at all.
        let differing = Set(values.filter { entry in entry.value.count > 1 || versions.contains { !$0.fields.contains { $0.name == entry.key } } }.keys)
        let columns = ForEach(Array(versions.enumerated()), id: \.element.choice.id) { index, version in
            VStack(alignment: .leading, spacing: 6) {
                Text("版本 \(index + 1)").font(.callout).foregroundStyle(.secondary)
                ForEach(version.fields.filter { !$0.value.isEmpty || differing.contains($0.name) }, id: \.name) { field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.name).foregroundStyle(.secondary)
                        Spacer()
                        Text(field.value.isEmpty ? "（空）" : field.value).monospacedDigit().multilineTextAlignment(.trailing)
                            .fontWeight(differing.contains(field.name) ? .bold : .regular)
                            .foregroundStyle(differing.contains(field.name) ? lifeWarnText : Color.primary)
                    }
                }
                Spacer(minLength: 4)
                Button { run { try store.resolveConflict(entityID: conflict.entityID, choosing: version.choice.id) } } label: {
                    Text("保留这个").frame(maxWidth: .infinity)
                }.buttonStyle(.lifeSecondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(lifeSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(lifeLine, lineWidth: 1))
        }
        return warningCard(title: conflict.kind == "timer" ? "同一条计时有不同的处理" : (conflict.kind == "transaction" ? "同一笔账有不同的修改" : "同一条时间记录有不同的修改")) {
            #if os(macOS)
            HStack(alignment: .top, spacing: 12) { columns }
            #else
            VStack(spacing: 12) { columns }
            #endif
            Text("不一样的地方用加粗的颜色标出。选定之前，这条记录不计入统计。").font(.callout).foregroundStyle(.secondary)
        }
    }
}
