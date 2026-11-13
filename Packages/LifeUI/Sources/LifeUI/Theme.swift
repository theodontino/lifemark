import SwiftUI
import LifeCore
import LifeStore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Colors (each has a light and a dark value; never a single fixed shade)

private func rgb(_ value: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
}
func lifeColor(light: UInt32, dark: UInt32) -> Color {
    let l = rgb(light), d = rgb(dark)
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? d : l
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #endif
}
/// Fills and primary buttons.
let lifeAccent = lifeColor(light: 0x17665C, dark: 0x4FD1B5)
/// Text placed on `lifeAccent`.
let lifeOnAccent = lifeColor(light: 0xFFFFFF, dark: 0x0B1F1A)
/// Accent-colored text and icons on the page or on `lifeAccentSoft`.
let lifeAccentText = lifeColor(light: 0x0F574E, dark: 0x7BE3CC)
let lifeAccentSoft = lifeColor(light: 0xE2F2EE, dark: 0x17302B)
let lifeAccentLine = lifeColor(light: 0xA5D3C9, dark: 0x2A5F54)
let lifeWarnText = lifeColor(light: 0x8A5800, dark: 0xF2B45A)
let lifeWarnSoft = lifeColor(light: 0xFFF3DB, dark: 0x2B2413)
let lifeWarnLine = lifeColor(light: 0xE5C27C, dark: 0x6B5327)
let lifeBadgeFill = Color(red: 0.95, green: 0.71, blue: 0.35)
let lifeBadgeText = Color(red: 0.12, green: 0.09, blue: 0.02)
let lifeGround = lifeColor(light: 0xF4F6F5, dark: 0x151718)
let lifeSurface = lifeColor(light: 0xFFFFFF, dark: 0x1F2324)
let lifeSidebar = lifeColor(light: 0xECEFED, dark: 0x1B1E1F)
let lifeLine = lifeColor(light: 0xDCE1DE, dark: 0x2C3233)
let lifeFieldLine = lifeColor(light: 0xAEB7B3, dark: 0x4A5356)

private let categoryPalette: [Color] = [
    lifeColor(light: 0x1F8A7A, dark: 0x4FD1B5), lifeColor(light: 0x7A5BC0, dark: 0xB79CE6),
    lifeColor(light: 0xB8651B, dark: 0xF0A45D), lifeColor(light: 0x3D6FC4, dark: 0x7FA6E0),
    lifeColor(light: 0xA77A00, dark: 0xF2B45A), lifeColor(light: 0xB8497F, dark: 0xE890BD),
    lifeColor(light: 0x4E7F2E, dark: 0x9BCB78), lifeColor(light: 0x6B7280, dark: 0xA7AEAB),
]
func timeCategoryColor(_ category: String) -> Color {
    if let index = timeCategories.firstIndex(of: category) { return categoryPalette[index % categoryPalette.count] }
    return categoryPalette[Int(category.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value } % UInt32(categoryPalette.count))]
}

// MARK: - Shared values and text helpers

let expenseCategories = ["餐饮", "交通", "购物", "日用", "娱乐", "订阅", "住房", "医疗", "学习", "其他"]
let timeCategories = ["工作", "学习", "创作", "通勤", "生活", "娱乐", "休息", "待分类"]
let lifeLocale = Locale(identifier: "zh_CN")
#if os(macOS)
let controlHeight: CGFloat = 36
let pagePadding: CGFloat = 32
#else
let controlHeight: CGFloat = 44
let pagePadding: CGFloat = 16
#endif

func durationText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)秒" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(minutes % 60)分"
}
func clockText(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}
func hourMinute(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}
func monthDay(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.month, .day], from: date)
    return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
}
func weekdayText(_ date: Date) -> String {
    ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][(Calendar.current.component(.weekday, from: date) + 6) % 7]
}
/// "今天 · 11月13日", "昨天 · 11月12日", or "11月10日 周二".
func relativeDay(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "今天 · " + monthDay(date) }
    if Calendar.current.isDateInYesterday(date) { return "昨天 · " + monthDay(date) }
    return monthDay(date) + " " + weekdayText(date)
}
func dayInterval(_ date: Date) -> DateInterval { Calendar.current.dateInterval(of: .day, for: date)! }
func periodLabel(_ period: DateInterval) -> String {
    monthDay(period.start) + " – " + monthDay(period.end.addingTimeInterval(-1))
}
extension TransactionKind {
    var label: String { switch self { case .expense: return "消费"; case .income: return "收入"; case .refund: return "退款"; case .transfer: return "转账 / 还款" } }
}
extension PurchaseAssessment {
    var label: String { switch self { case .unrated: return "尚未评价"; case .worthwhile: return "值得"; case .regretted: return "后悔这笔"; case .occasional: return "偶尔可以" } }
}
extension RecordSource {
    var label: String { switch self { case .manual: return "手工"; case .screenshot: return "截图"; case .screen: return "Mac 屏幕摘要"; case .location: return "iPhone 定位" } }
}

// MARK: - Controls

struct LifeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, onAccentSoft, danger }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View { Face(kind: kind, compact: compact, configuration: configuration) }
    private struct Face: View {
        let kind: Kind, compact: Bool, configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        private var foreground: Color {
            switch kind { case .primary: return lifeOnAccent; case .secondary: return .primary; case .onAccentSoft: return lifeAccentText; case .danger: return .red }
        }
        private var stroke: Color {
            switch kind { case .primary: return .clear; case .secondary: return lifeFieldLine; case .onAccentSoft: return lifeAccentLine; case .danger: return Color.red.opacity(0.5) }
        }
        var body: some View {
            configuration.label
                .font(.body.weight(kind == .primary ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, compact ? 12 : 16).frame(minHeight: compact ? 32 : controlHeight)
                .foregroundStyle(foreground)
                .background(kind == .primary ? lifeAccent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(stroke, lineWidth: 1))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
extension ButtonStyle where Self == LifeButtonStyle {
    static var lifePrimary: LifeButtonStyle { LifeButtonStyle(kind: .primary) }
    static var lifeSecondary: LifeButtonStyle { LifeButtonStyle(kind: .secondary) }
    static var lifeDanger: LifeButtonStyle { LifeButtonStyle(kind: .danger) }
}

/// Wraps its children onto as many rows as the width needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(result.sizes[index]))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], sizes: [CGSize], size: CGSize) {
        var points: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, used: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if width.isFinite, size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); used = max(used, x - spacing)
        }
        return (points, sizes, CGSize(width: used, height: y + rowHeight))
    }
}

struct Chip: View {
    let title: String, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.callout).lineLimit(1).padding(.horizontal, 12).frame(minHeight: controlHeight - 6)
                .foregroundStyle(selected ? lifeAccentText : Color.primary)
                .background(selected ? lifeAccentSoft : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? lifeAccent : lifeFieldLine, lineWidth: 1))
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
/// One-of-many choice shown as chips; a value outside `options` is appended so it stays visible.
struct ChipPicker: View {
    let options: [String]
    @Binding var selection: String
    var body: some View {
        FlowLayout {
            ForEach(options.contains(selection) || selection.isEmpty ? options : options + [selection], id: \.self) { option in
                Chip(title: option, selected: option == selection) { selection = option }
            }
        }
    }
}
struct Tag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption).lineLimit(1).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.5), lineWidth: 1))
    }
}
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}
extension View {
    /// A text field with a visible boundary.
    func lifeField() -> some View {
        self.textFieldStyle(.plain).padding(.horizontal, 12).frame(minHeight: controlHeight)
            .background(lifeGround, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(lifeFieldLine, lineWidth: 1))
    }
    // Use the native decimal keyboard on iPhone while retaining the Mac text field.
    @ViewBuilder func moneyInput() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
struct PeriodNav: View {
    let label: String, previousLabel: String, nextLabel: String
    let previous: () -> Void, next: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(action: previous) { Image(systemName: "chevron.left") }.buttonStyle(LifeButtonStyle(compact: true)).accessibilityLabel(previousLabel)
            Text(label).fontWeight(.semibold).monospacedDigit().lineLimit(1).padding(.horizontal, 8)
            Button(action: next) { Image(systemName: "chevron.right") }.buttonStyle(LifeButtonStyle(compact: true)).accessibilityLabel(nextLabel)
        }.frame(minHeight: controlHeight)
    }
}

// MARK: - Page building blocks

struct PageScroll<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(pagePadding).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
        }.background(lifeGround)
    }
}
/// Title on the left (Mac only: iPhone shows it in the navigation bar), controls wrapping on the right.
struct PageHeader<Controls: View>: View {
    let title: String
    var subtitle = ""
    private let controls: Controls
    init(_ title: String, subtitle: String = "", @ViewBuilder controls: () -> Controls) {
        self.title = title; self.subtitle = subtitle; self.controls = controls()
    }
    var body: some View {
        #if os(macOS)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title.bold())
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }.fixedSize()
            Spacer(minLength: 0)
            FlowLayout(spacing: 10) { controls }
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            FlowLayout(spacing: 10) { controls }
        }
        #endif
    }
}
/// Side-by-side on the Mac, stacked on iPhone.
struct TwoColumns<Left: View, Right: View>: View {
    private let left: Left, right: Right
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) { self.left = left(); self.right = right() }
    var body: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) { left }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) { right }.frame(width: 320, alignment: .leading)
        }
        #else
        VStack(alignment: .leading, spacing: 16) { left; right }
        #endif
    }
}
struct Panel<Content: View>: View {
    let title: String
    private let content: Content
    init(_ title: String = "", @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { Text(title).font(.headline) }
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 16)
          .background(lifeSurface, in: RoundedRectangle(cornerRadius: 14))
          .overlay(RoundedRectangle(cornerRadius: 14).stroke(lifeLine, lineWidth: 1))
    }
}
/// The one number a page leads with.
struct BigFigure: View {
    let value: String, caption: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).foregroundStyle(.secondary)
        }
    }
}
struct BarRow: View {
    let label: String, value: String, fraction: Double
    var color: Color = lifeAccent
    var body: some View {
        VStack(spacing: 5) {
            HStack { Text(label).lineLimit(1); Spacer(); Text(value).monospacedDigit() }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(lifeLine)
                    Capsule().fill(color).frame(width: max(6, geometry.size.width * min(1, max(0, fraction))))
                }
            }.frame(height: 8)
        }.accessibilityElement(children: .combine)
    }
}
struct EmptyRecords: View {
    let title: String, detail: String
    var icon = "tray"
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title).foregroundStyle(lifeAccentText)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}
struct ErrorText: View {
    let text: String?
    var body: some View { if let text { Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled) } }
}

// MARK: - Record rows

struct TransactionLine: View {
    let item: LifeCore.Transaction
    var showsDate = false
    private var amount: String {
        switch item.kind { case .refund, .income: return "+" + Money.format(item.amountCents); default: return Money.format(item.amountCents) }
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.merchant.isEmpty ? item.category : item.merchant).fontWeight(.semibold).lineLimit(1)
                Text("\(item.category) · \(item.account) · \(showsDate ? monthDay(item.date) + " " : "")\(hourMinute(item.date))")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.status == .pending { Tag(text: "待核对", color: lifeWarnText) }
            else if item.kind == .expense, item.assessment == .regretted { Tag(text: "后悔这笔", color: lifeWarnText) }
            else if item.kind != .expense { Tag(text: item.kind.label, color: item.kind == .transfer ? .secondary : lifeAccentText) }
            Text(amount).fontWeight(.semibold).monospacedDigit().foregroundStyle(item.kind == .refund || item.kind == .income ? lifeAccentText : Color.primary)
        }.frame(minHeight: 52).contentShape(Rectangle())
    }
}
struct TimeLine: View {
    let block: TimeBlock
    var body: some View {
        HStack(spacing: 12) {
            Text("\(hourMinute(block.start)) – \(hourMinute(block.end))").font(.callout).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            Text(block.title).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 8)
            if block.status == .pending { Tag(text: "待核对", color: lifeWarnText) }
            Text(block.category).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(durationText(block.end.timeIntervalSince(block.start))).monospacedDigit().fixedSize()
        }.frame(minHeight: 48).contentShape(Rectangle())
    }
}
/// Rows with hairlines between them, each opening `action` when clicked.
struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let action: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(lifeLine).frame(height: 1) }
                Button { action(item) } label: { row(item) }.buttonStyle(.plain)
            }
        }
    }
}
