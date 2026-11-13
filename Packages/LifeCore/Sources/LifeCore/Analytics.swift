import Foundation

public struct FinanceSummary: Equatable, Sendable {
    public var expenseCents: Int = 0
    public var refundCents: Int = 0
    public var netExpenseCents: Int = 0
    public var incomeCents: Int = 0
    public var balanceCents: Int = 0
    public var categoryExpenses: [String: Int] = [:]
    public var confirmedCount: Int = 0
    public init() {}
}
public struct TimeSummary: Equatable, Sendable {
    public var summedSeconds: Double = 0
    public var occupiedSeconds: Double = 0
    public var overlapSeconds: Double = 0
    public var categorySeconds: [String: Double] = [:]
    public var confirmedCount: Int = 0
    public init() {}
}
public enum Analytics {
    public static func billingPeriod(containing date: Date, startDay: Int, calendar: Calendar = .current) -> DateInterval {
        let day = min(31, max(1, startDay))
        let month = calendar.dateInterval(of: .month, for: date)!.start
        func anchor(_ month: Date) -> Date {
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = min(day, calendar.range(of: .day, in: .month, for: month)!.count)
            return calendar.date(from: components)!
        }
        let candidate = anchor(month)
        let startMonth = candidate <= date ? month : calendar.date(byAdding: .month, value: -1, to: month)!
        let endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth)!
        return DateInterval(start: anchor(startMonth), end: anchor(endMonth))
    }

    public static func finance(_ transactions: [Transaction], in period: DateInterval) -> FinanceSummary {
        var result = FinanceSummary()
        for item in transactions where item.currency == "CNY" && item.status == .confirmed && item.amountCents >= 0 && item.date >= period.start && item.date < period.end && item.kind != .transfer {
            result.confirmedCount += 1
            switch item.kind {
            case .expense:
                result.expenseCents += item.amountCents
                result.categoryExpenses[item.category, default: 0] += item.amountCents
            case .refund:
                result.refundCents += item.amountCents
                result.categoryExpenses[item.category, default: 0] -= item.amountCents
            case .income: result.incomeCents += item.amountCents
            case .transfer: break
            }
        }
        result.netExpenseCents = result.expenseCents - result.refundCents
        result.balanceCents = result.incomeCents - result.netExpenseCents
        return result
    }
    public static func time(_ blocks: [TimeBlock], in period: DateInterval) -> TimeSummary {
        var result = TimeSummary()
        var intervals: [(Date, Date)] = []
        for block in blocks where block.status == .confirmed && block.end > block.start {
            let start = max(block.start, period.start), end = min(block.end, period.end)
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            result.confirmedCount += 1
            result.summedSeconds += seconds
            result.categorySeconds[block.category, default: 0] += seconds
            intervals.append((start, end))
        }
        intervals.sort { $0.0 < $1.0 }
        var merged: (Date, Date)?
        for interval in intervals {
            if let current = merged {
                if interval.0 <= current.1 { merged = (current.0, max(current.1, interval.1)) }
                else { result.occupiedSeconds += current.1.timeIntervalSince(current.0); merged = interval }
            } else { merged = interval }
        }
        if let current = merged { result.occupiedSeconds += current.1.timeIntervalSince(current.0) }
        result.overlapSeconds = max(0, result.summedSeconds - result.occupiedSeconds)
        return result
    }
    public static func suggestions(transactions: [Transaction], blocks: [TimeBlock], period: DateInterval, budgetCents: Int) -> [String] {
        let money = finance(transactions, in: period), duration = time(blocks, in: period)
        var suggestions: [String] = []
        let pending = transactions.filter { $0.status == .pending && $0.date >= period.start && $0.date < period.end }.count + blocks.filter { $0.status == .pending && $0.start < period.end && $0.end > period.start }.count
        if pending > 0 { suggestions.append("本账期有 \(pending) 条记录待确认，确认后才会计入统计。") }
        if money.confirmedCount == 0 { suggestions.append("本账期还没有已确认的收支记录，可以先记下今天的一笔。") }
        if budgetCents > 0 && money.netExpenseCents > budgetCents { suggestions.append("已记录的净支出超出预算 \(Money.format(money.netExpenseCents - budgetCents))，可以核对大额支出和退款。") }
        if duration.overlapSeconds >= 60 { suggestions.append("时间记录有 \(Int(duration.overlapSeconds / 60)) 分钟重叠，时间总量已按实际占用去重；可以检查是否为同时进行的活动。") }
        if duration.confirmedCount == 0 { suggestions.append("本账期还没有已确认的时间记录，少量记录也能帮助回顾一天。") }
        if suggestions.isEmpty { suggestions.append("当前记录已整理完成；这些统计仅反映已记录的部分，可以继续补充遗漏。") }
        return suggestions
    }
}
