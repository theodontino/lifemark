import SwiftUI
import LifeCore
import LifeStore

let lifeAccent = Color(red: 0.12, green: 0.40, blue: 0.36)
let expenseCategories = ["餐饮", "交通", "购物", "日用", "娱乐", "订阅", "住房", "医疗", "学习", "其他"]
let timeCategories = ["工作", "学习", "创作", "通勤", "生活", "娱乐", "休息", "待分类"]
func durationText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)秒" }
    let minutes = total / 60
    return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分钟"
}
func dayInterval(_ date: Date) -> DateInterval { Calendar.current.dateInterval(of: .day, for: date)! }
func periodLabel(_ period: DateInterval) -> String {
    period.start.formatted(.dateTime.month().day()) + " — " + period.end.addingTimeInterval(-1).formatted(.dateTime.month().day())
}
extension TransactionKind {
    var label: String { switch self { case .expense: return "消费"; case .income: return "收入"; case .refund: return "退款"; case .transfer: return "转账 / 还款" } }
    var icon: String { switch self { case .expense: return "arrow.up.right"; case .income: return "arrow.down.left"; case .refund: return "arrow.uturn.backward"; case .transfer: return "arrow.left.arrow.right" } }
}
extension PurchaseAssessment {
    var label: String { switch self { case .unrated: return "尚未评价"; case .worthwhile: return "值得"; case .regretted: return "后悔这笔"; case .occasional: return "偶尔可以" } }
}
extension RecordSource {
    var label: String { switch self { case .manual: return "手工"; case .screenshot: return "截图"; case .screen: return "屏幕线索"; case .location: return "位置线索" } }
}
struct Panel<Content: View>: View {
    let title: String
    var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty { Text(title).font(.headline) }
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
          .background(.background, in: RoundedRectangle(cornerRadius: 18))
          .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.08)))
    }
}
struct Metric: View {
    let title: String; let value: String; var caption: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).minimumScaleFactor(0.6).lineLimit(1)
            if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct EmptyRecords: View {
    let title: String; let detail: String; var icon: String = "tray"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(lifeAccent)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}
struct ErrorText: View {
    let text: String?
    var body: some View { if let text { Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled) } }
}
struct TransactionLine: View {
    let item: LifeCore.Transaction
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.icon).frame(width: 36, height: 36).background(lifeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.merchant.isEmpty ? item.category : item.merchant).fontWeight(.medium)
                Text("\(item.category) · \(item.account) · \(item.date.formatted(.dateTime.month().day()))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Money.format(item.amountCents)).monospacedDigit()
                Text(item.status == .pending ? "待核对" : item.kind.label).font(.caption).foregroundStyle(item.status == .pending ? .orange : .secondary)
            }
        }.foregroundStyle(.primary).contentShape(Rectangle())
    }
}
struct TimeLine: View {
    let block: TimeBlock
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(block.status == .pending ? .orange : lifeAccent).frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(block.title).fontWeight(.medium)
                Text("\(block.start.formatted(.dateTime.hour().minute())) — \(block.end.formatted(.dateTime.hour().minute())) · \(durationText(block.end.timeIntervalSince(block.start)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(block.category).font(.caption)
                Text(block.status == .pending ? "待核对 · \(block.source.label)" : block.source.label).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 45).foregroundStyle(.primary).contentShape(Rectangle())
    }
}

// Use the native decimal keyboard on iPhone while retaining the Mac text field.
extension View {
    @ViewBuilder func moneyInput() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
