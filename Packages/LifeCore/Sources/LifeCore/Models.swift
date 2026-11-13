import Foundation

public enum TransactionKind: String, Codable, CaseIterable, Sendable { case expense, income, refund, transfer }
public enum RecordSource: String, Codable, CaseIterable, Sendable { case manual, screenshot, location, screen }
public enum ReviewStatus: String, Codable, CaseIterable, Sendable { case confirmed, pending }

public enum PurchaseAssessment: String, Codable, CaseIterable, Sendable { case unrated, worthwhile, regretted, occasional }

public struct Transaction: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var amountCents: Int
    public var kind: TransactionKind
    public var category: String
    public var merchant: String
    public var date: Date
    public var note: String
    public var source: RecordSource
    public var status: ReviewStatus
    public var fingerprint: String?
    public var account: String
    public var assessment: PurchaseAssessment
    public var originalTransactionID: UUID?
    public var currency: String
    public init(id: UUID = UUID(), amountCents: Int, kind: TransactionKind, category: String, merchant: String, date: Date = Date(), note: String = "", source: RecordSource = .manual, status: ReviewStatus = .confirmed, fingerprint: String? = nil, account: String = "默认账户", assessment: PurchaseAssessment = .unrated, originalTransactionID: UUID? = nil, currency: String = "CNY") {
        self.id = id; self.amountCents = amountCents; self.kind = kind; self.category = category; self.merchant = merchant; self.date = date; self.note = note; self.source = source; self.status = status; self.fingerprint = fingerprint; self.account = account; self.assessment = assessment; self.originalTransactionID = originalTransactionID; self.currency = currency
    }
    private enum CodingKeys: String, CodingKey {
        case id, amountCents, kind, category, merchant, date, note, source, status, fingerprint
        case account, assessment, originalTransactionID, currency
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            amountCents: try c.decode(Int.self, forKey: .amountCents),
            kind: try c.decode(TransactionKind.self, forKey: .kind),
            category: try c.decode(String.self, forKey: .category),
            merchant: try c.decode(String.self, forKey: .merchant),
            date: try c.decode(Date.self, forKey: .date),
            note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
            source: try c.decodeIfPresent(RecordSource.self, forKey: .source) ?? .manual,
            status: try c.decodeIfPresent(ReviewStatus.self, forKey: .status) ?? .confirmed,
            fingerprint: try c.decodeIfPresent(String.self, forKey: .fingerprint),
            account: try c.decodeIfPresent(String.self, forKey: .account) ?? "默认账户",
            assessment: try c.decodeIfPresent(PurchaseAssessment.self, forKey: .assessment) ?? .unrated,
            originalTransactionID: try c.decodeIfPresent(UUID.self, forKey: .originalTransactionID),
            currency: try c.decodeIfPresent(String.self, forKey: .currency) ?? "CNY"
        )
    }

}
public struct TimeBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var category: String
    public var start: Date
    public var end: Date
    public var note: String
    public var source: RecordSource
    public var status: ReviewStatus
    public var evidence: String
    public init(id: UUID = UUID(), title: String, category: String, start: Date, end: Date, note: String = "", source: RecordSource = .manual, status: ReviewStatus = .confirmed, evidence: String = "") {
        self.id = id; self.title = title; self.category = category; self.start = start; self.end = end; self.note = note; self.source = source; self.status = status; self.evidence = evidence
    }
}
public struct AppData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var transactions: [Transaction]
    public var timeBlocks: [TimeBlock]
    public var monthlyBudgetCents: Int
    public var billingStartDay: Int
    public init(schemaVersion: Int = 1, transactions: [Transaction] = [], timeBlocks: [TimeBlock] = [], monthlyBudgetCents: Int = 0, billingStartDay: Int = 1) {
        self.schemaVersion = schemaVersion; self.transactions = transactions; self.timeBlocks = timeBlocks; self.monthlyBudgetCents = monthlyBudgetCents; self.billingStartDay = billingStartDay
    }
}
public enum Money {
    public static func parseCents(_ text: String) -> Int? {
        var value = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["¥", "￥", "人民币", "CNY"] where value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if value.hasSuffix("元") { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard value.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.replacingOccurrences(of: ",", with: "").split(separator: ".")
        guard let whole = Int(parts[0]), whole <= Int.max / 100 else { return nil }
        let fractional = parts.count == 2 ? Int(parts[1])! * (parts[1].count == 1 ? 10 : 1) : 0
        let (result, overflow) = (whole * 100).addingReportingOverflow(fractional)
        return overflow ? nil : result
    }
    public static func format(_ cents: Int) -> String {
        let magnitude = cents.magnitude
        return "¥ " + (cents < 0 ? "-" : "") + String(magnitude / 100) + "." + String(format: "%02d", Int(magnitude % 100))
    }
}
