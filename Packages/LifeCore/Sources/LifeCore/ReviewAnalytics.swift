import Foundation

public struct MonthlySpending: Identifiable, Equatable, Sendable {
    public var id: String
    public var month: Date
    public var expenseCents: Int
    public var refundCents: Int
    public var netExpenseCents: Int
    public var transactionCount: Int
    public var categoryExpenses: [String: Int]
}
public struct MerchantPattern: Identifiable, Equatable, Sendable {
    public var id: String
    public var merchant: String
    public var count: Int
    public var totalCents: Int
    public var averageCents: Int
}
public struct TaskDurationPattern: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var count: Int
    public var totalSeconds: Double
    public var averageSeconds: Double
    public var medianSeconds: Double
}
public struct RecordedMonthAverage: Equatable, Sendable {
    public var recordedMonthCount: Int
    public var averageNetExpenseCents: Int?
}
public enum ReviewAnalytics {
    /// Includes the current partial month through `asOf`, with empty months explicitly present.
    public static func monthly(transactions: [Transaction], asOf: Date = Date(), months: Int = 6) -> [MonthlySpending] {
        let calendar = Calendar.current
        guard months > 0, let current = calendar.dateInterval(of: .month, for: asOf)?.start else { return [] }
        return (0..<min(months, 120)).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: current), let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            let eligible = transactions.filter { $0.date <= asOf }
            let summary = Analytics.finance(eligible, in: DateInterval(start: start, end: end))
            let c = calendar.dateComponents([.year, .month], from: start)
            return MonthlySpending(id: String(format: "%04d-%02d", c.year!, c.month!), month: start, expenseCents: summary.expenseCents, refundCents: summary.refundCents, netExpenseCents: summary.netExpenseCents, transactionCount: summary.confirmedCount, categoryExpenses: summary.categoryExpenses)
        }
    }
    /// A recorded month is a month with at least one eligible confirmed entry; this is not coverage of an entire month.
    public static func recordedMonthAverage(_ months: [MonthlySpending]) -> RecordedMonthAverage {
        let recorded = months.filter { $0.transactionCount > 0 }
        return RecordedMonthAverage(recordedMonthCount: recorded.count, averageNetExpenseCents: recorded.isEmpty ? nil : recorded.reduce(0) { $0 + $1.netExpenseCents } / recorded.count)
    }
    /// Frequency counts purchases only. Refunds do not count as additional visits or purchases.
    public static func merchants(transactions: [Transaction], period: DateInterval) -> [MerchantPattern] {
        let eligible = transactions.filter { $0.currency == "CNY" && $0.status == .confirmed && $0.kind == .expense && $0.amountCents >= 0 && $0.date >= period.start && $0.date < period.end }
        return Dictionary(grouping: eligible, by: { $0.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写商户" : $0.merchant.trimmingCharacters(in: .whitespacesAndNewlines) }).map { merchant, entries in
            let total = entries.reduce(0) { $0 + $1.amountCents }
            return MerchantPattern(id: merchant, merchant: merchant, count: entries.count, totalCents: total, averageCents: total / entries.count)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : ($0.totalCents != $1.totalCents ? $0.totalCents > $1.totalCents : $0.merchant < $1.merchant) }
    }
    /// Durations are clipped to the selected period. Concurrent tasks retain their individual duration.
    public static func taskDurations(blocks: [TimeBlock], period: DateInterval) -> [TaskDurationPattern] {
        let eligible = blocks.filter { $0.status == .confirmed && $0.end > $0.start && $0.start < period.end && $0.end > period.start }
        return Dictionary(grouping: eligible, by: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名事项" : $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }).map { title, entries in
            let values = entries.map { min($0.end, period.end).timeIntervalSince(max($0.start, period.start)) }.sorted()
            let total = values.reduce(0, +), middle = values.count / 2
            let median = values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
            return TaskDurationPattern(id: title, title: title, count: entries.count, totalSeconds: total, averageSeconds: total / Double(entries.count), medianSeconds: median)
        }.sorted { $0.totalSeconds != $1.totalSeconds ? $0.totalSeconds > $1.totalSeconds : $0.title < $1.title }
    }
    /// Reflects the user's own assessment only; no judgment is inferred from amount or frequency.
    public static func regrettedSpending(transactions: [Transaction], period: DateInterval) -> Int {
        transactions.filter { $0.currency == "CNY" && $0.status == .confirmed && $0.kind == .expense && $0.assessment == .regretted && $0.amountCents >= 0 && $0.date >= period.start && $0.date < period.end }.reduce(0) { $0 + $1.amountCents }
    }
}
