import Foundation

public struct ReceiptDraft: Equatable, Sendable {
    public var amountCents: Int?
    public var kind: TransactionKind
    public var merchant: String
    public var date: Date?
    public var note: String
    public init(amountCents: Int?, kind: TransactionKind, merchant: String, date: Date?, note: String) {
        self.amountCents = amountCents; self.kind = kind; self.merchant = merchant; self.date = date; self.note = note
    }
}

/// Conservative rules for Chinese payment screenshots. Missing or conflicting evidence stays empty.
public enum ReceiptParser {
    public static func parse(_ text: String, referenceDate: Date = Date()) -> ReceiptDraft {
        let text = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let refund = ["退款成功", "已退款", "退款到账", "退款金额", "退回金额"].contains(where: text.contains)
        let kind: TransactionKind = refund ? .refund : (text.contains("转账成功") ? .transfer : (["收入金额", "收款金额", "收款成功", "到账金额"].contains(where: text.contains) ? .income : .expense))
        let tiers: [[String]] = refund
          ? [["退款金额", "退回金额", "退款到账"], ["实付款", "实付金额", "实际支付", "实付", "付款金额", "支付金额"]]
          : [["实付款", "实付金额", "实际支付", "实付", "付款金额", "支付金额", "收入金额", "收款金额", "到账金额"], ["订单金额", "交易金额", "消费金额"]]
        var amount: Int?
        var foundLabel = false
        for labels in tiers {
            var candidates: Set<Int> = []
            for (index, line) in lines.enumerated() {
                guard let label = labels.first(where: line.contains), let range = line.range(of: label) else { continue }
                foundLabel = true
                let tail = String(line[range.upperBound...])
                let sameLine = amounts(tail)
                if !sameLine.isEmpty { candidates.formUnion(sameLine) }
                else if index + 1 < lines.count, isAmountOnly(lines[index + 1]) { candidates.formUnion(amounts(lines[index + 1])) }
            }
            if !candidates.isEmpty { amount = candidates.count == 1 ? candidates.first : nil; break }
        }
        if !foundLabel {
            // Only accept a standalone currency amount, never a balance or an order-number line.
            let candidates = Set(lines.filter { isAmountOnly($0) && ($0.contains("¥") || $0.contains("￥") || $0.hasSuffix("元")) }.flatMap(amounts))
            if candidates.count == 1 { amount = candidates.first }
        }
        var merchant = ""
        for (index, line) in lines.enumerated() {
            let labels = ["商户名称", "商家名称", "收款方", "付款给", "商户", "商家"]
            if let label = labels.first(where: line.hasPrefix) {
                let value = String(line.dropFirst(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                if !value.isEmpty { merchant = value; break }
                if index + 1 < lines.count { merchant = lines[index + 1]; break }
            }
        }
        return ReceiptDraft(amountCents: amount, kind: kind, merchant: merchant, date: parseDate(text, referenceDate: referenceDate), note: amount == nil ? "金额待核对；请根据原图确认。" : "由截图识别，请核对后保存。")
    }

    private static func isAmountOnly(_ line: String) -> Bool {
        line.range(of: #"^[：:\s]*[¥￥]?\s*(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?\s*元?\s*$"#, options: .regularExpression) != nil
    }
    private static func amounts(_ text: String) -> [Int] {
        let pattern = #"(?<![0-9.,-])(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?(?![0-9.,])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            return Money.parseCents(String(text[range]))
        }
    }
    private static func parseDate(_ text: String, referenceDate: Date) -> Date? {
        let pattern = #"(20[0-9]{2})[-/年]([0-9]{1,2})[-/月]([0-9]{1,2})日?(?:\s+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func number(_ n: Int, fallback: Int = 0) -> Int { guard let r = Range(match.range(at: n), in: text) else { return fallback }; return Int(text[r]) ?? fallback }
            let y = number(1), m = number(2), d = number(3), h = number(4), minute = number(5), second = number(6)
            let components = DateComponents(year: y, month: m, day: d, hour: h, minute: minute, second: second)
            guard let date = calendar.date(from: components), calendar.component(.year, from: date) == y, calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d, h < 24, minute < 60, second < 60, date <= referenceDate.addingTimeInterval(86400) else { continue }
            return date
        }
        return nil
    }
}
