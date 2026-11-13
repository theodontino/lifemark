import XCTest
@testable import LifeCore

final class LifeCoreTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var period: DateInterval { DateInterval(start: date("2026-11-01T00:00:00Z"), end: date("2026-12-01T00:00:00Z")) }
    private func purchase(_ amount: Int, kind: TransactionKind = .expense, status: ReviewStatus = .confirmed, at: Date? = nil, currency: String = "CNY") -> Transaction {
        Transaction(amountCents: amount, kind: kind, category: "餐饮", merchant: "食堂", date: at ?? date("2026-11-05T12:00:00Z"), status: status, currency: currency)
    }
    func testMoneyExactAndInvalidInputs() {
        XCTAssertEqual(Money.parseCents("￥ 1,234.56元"), 123456)
        XCTAssertEqual(Money.parseCents("0.01"), 1)
        XCTAssertEqual(Money.parseCents("19.9"), 1990)
        for text in ["-1", "1.001", "NaN", "inf", "1e4", "12,34.00", "", "92233720368547758.08", "999999999999999999999"] { XCTAssertNil(Money.parseCents(text), text) }
        XCTAssertEqual(Money.format(-105), "¥ -1.05")
        XCTAssertFalse(Money.format(Int.min).isEmpty)
    }
    func testReceiptPrioritizesActualPaymentOverOriginalBalanceAndOrder() {
        let draft = ReceiptParser.parse("商户名称：便利店\n原价 ¥99.00\n实付款 ¥32.50\n账户余额 ¥9800.00\n订单编号 202611050001", referenceDate: date("2026-11-12T12:00:00Z"))
        XCTAssertEqual(draft.amountCents, 3250)
        XCTAssertEqual(draft.merchant, "便利店")
        XCTAssertEqual(draft.kind, .expense)
    }
    func testReceiptSplitAmountAndUnknown() {
        XCTAssertEqual(ReceiptParser.parse("支付成功\n实付金额\n￥ 28.60\n订单号 88888888").amountCents, 2860)
        XCTAssertNil(ReceiptParser.parse("支付成功\n订单编号 202611050001\n账户余额 ¥9800.00").amountCents)
        XCTAssertNil(ReceiptParser.parse("实付 20.00\n支付金额 30.00").amountCents)
        XCTAssertNil(ReceiptParser.parse("实付 12.345").amountCents)
        XCTAssertNil(ReceiptParser.parse("实付金额\n订单编号 123456").amountCents)
    }
    func testRefundAndDateEvidence() {
        let draft = ReceiptParser.parse("退款成功\n退款金额 ￥8.00\n原实付 ￥20.00\n2026-11-05 12:30:40", referenceDate: date("2026-11-12T12:00:00Z"))
        XCTAssertEqual(draft.kind, .refund)
        XCTAssertEqual(draft.amountCents, 800)
        XCTAssertNotNil(draft.date)
        XCTAssertNil(ReceiptParser.parse("实付 20\n2026-02-31 12:30", referenceDate: date("2026-11-12T12:00:00Z")).date)
        XCTAssertNil(ReceiptParser.parse("实付20").date)
    }
    func testFinanceRefundsIncomeTransfersPendingAndCurrency() {
        let summary = Analytics.finance([purchase(5000), purchase(1000, kind: .refund), purchase(8000, kind: .income), purchase(99999, kind: .transfer), purchase(9000, status: .pending), purchase(7000, currency: "USD"), purchase(-1)], in: period)
        XCTAssertEqual(summary.expenseCents, 5000)
        XCTAssertEqual(summary.refundCents, 1000)
        XCTAssertEqual(summary.netExpenseCents, 4000)
        XCTAssertEqual(summary.incomeCents, 8000)
        XCTAssertEqual(summary.balanceCents, 4000)
        XCTAssertEqual(summary.confirmedCount, 3)
        XCTAssertEqual(summary.categoryExpenses["餐饮"], 4000)
    }
    func testHalfOpenRangeAndRefundInLaterMonth() {
        let summary = Analytics.finance([purchase(100, at: period.start), purchase(500, at: period.end), purchase(300, kind: .refund)], in: period)
        XCTAssertEqual(summary.expenseCents, 100)
        XCTAssertEqual(summary.netExpenseCents, -200)
    }
    func testBillingCrossYearAndBoundaries() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = Analytics.billingPeriod(containing: date("2026-01-14T23:59:59Z"), startDay: 15, calendar: calendar)
        XCTAssertEqual(before.start, date("2025-12-15T00:00:00Z"))
        XCTAssertEqual(before.end, date("2026-01-15T00:00:00Z"))
        let boundary = Analytics.billingPeriod(containing: before.end, startDay: 15, calendar: calendar)
        XCTAssertEqual(boundary.start, before.end)
        XCTAssertEqual(Analytics.billingPeriod(containing: date("2026-02-28T12:00:00Z"), startDay: 31, calendar: calendar).start, date("2026-02-28T00:00:00Z"))
    }
    func testBillingLastDayAnchorsDoNotDriftAfterFebruary() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let february = Analytics.billingPeriod(containing: date("2026-02-28T12:00:00Z"), startDay: 31, calendar: calendar)
        XCTAssertEqual(february.start, date("2026-02-28T00:00:00Z"))
        XCTAssertEqual(february.end, date("2026-03-31T00:00:00Z"))
        let beforeFebruary = Analytics.billingPeriod(containing: date("2026-02-27T12:00:00Z"), startDay: 31, calendar: calendar)
        XCTAssertEqual(beforeFebruary.start, date("2026-01-31T00:00:00Z"))
        XCTAssertEqual(beforeFebruary.end, date("2026-02-28T00:00:00Z"))
        let leap = Analytics.billingPeriod(containing: date("2028-02-29T00:00:00Z"), startDay: 31, calendar: calendar)
        XCTAssertEqual(leap.start, date("2028-02-29T00:00:00Z"))
        XCTAssertEqual(leap.end, date("2028-03-31T00:00:00Z"))
        XCTAssertEqual(Analytics.billingPeriod(containing: february.end, startDay: 31, calendar: calendar).start, february.end)
    }
    func testTimeUnionClipsMidnightAndSkipsInvalidAndPending() {
        let start = date("2026-11-05T00:00:00Z")
        let day = DateInterval(start: start, duration: 86400)
        let blocks = [
            TimeBlock(title: "阅读", category: "学习", start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(3600)),
            TimeBlock(title: "听课", category: "学习", start: start.addingTimeInterval(1800), end: start.addingTimeInterval(5400)),
            TimeBlock(title: "重复", category: "学习", start: start, end: start.addingTimeInterval(3600)),
            TimeBlock(title: "无效", category: "学习", start: start, end: start),
            TimeBlock(title: "待确认", category: "学习", start: start, end: day.end, status: .pending),
            TimeBlock(title: "次日", category: "学习", start: day.end, end: day.end.addingTimeInterval(3600))]
        let result = Analytics.time(blocks, in: day)
        XCTAssertEqual(result.summedSeconds, 10800)
        XCTAssertEqual(result.occupiedSeconds, 5400)
        XCTAssertEqual(result.overlapSeconds, 5400)
        XCTAssertEqual(result.confirmedCount, 3)
    }
    func testMonthlyPartialCoverageDoesNotInventEmptyMonthAverage() {
        let asOf = date("2026-11-12T12:00:00Z")
        let values = ReviewAnalytics.monthly(transactions: [purchase(1000), purchase(500, status: .pending), purchase(300, at: date("2026-12-05T12:00:00Z")), purchase(800, currency: "USD")], asOf: asOf, months: 3)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.last?.netExpenseCents, 1000)
        XCTAssertEqual(values.last?.transactionCount, 1)
        XCTAssertEqual(ReviewAnalytics.recordedMonthAverage(values).recordedMonthCount, 1)
        XCTAssertEqual(ReviewAnalytics.recordedMonthAverage(values).averageNetExpenseCents, 1000)
        XCTAssertNil(ReviewAnalytics.recordedMonthAverage(ReviewAnalytics.monthly(transactions: [], asOf: asOf)).averageNetExpenseCents)
        XCTAssertTrue(ReviewAnalytics.monthly(transactions: [], months: 0).isEmpty)
    }
    func testMerchantFrequencyCountsPurchasesAndStableSort() {
        let rows = ReviewAnalytics.merchants(transactions: [purchase(100), purchase(300), purchase(100, kind: .refund), purchase(100, kind: .transfer), purchase(100, status: .pending)], period: period)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(rows.first?.totalCents, 400)
        XCTAssertEqual(rows.first?.averageCents, 200)
    }
    func testTaskMedianClippingAndAssessment() {
        let start = period.start
        var blocks = [10.0, 20, 90].map { TimeBlock(title: "备课", category: "工作", start: start, end: start.addingTimeInterval($0)) }
        let odd = ReviewAnalytics.taskDurations(blocks: blocks, period: period)[0]
        XCTAssertEqual(odd.medianSeconds, 20)
        XCTAssertEqual(odd.averageSeconds, 40)
        blocks.append(TimeBlock(title: "备课", category: "工作", start: start.addingTimeInterval(-100), end: start.addingTimeInterval(30)))
        XCTAssertEqual(ReviewAnalytics.taskDurations(blocks: blocks, period: period)[0].medianSeconds, 25)
        var regretted = purchase(1000); regretted.assessment = .regretted
        XCTAssertEqual(ReviewAnalytics.regrettedSpending(transactions: [regretted, purchase(500000)], period: period), 1000)
    }
    func testLegacyTransactionDecodesDefaults() throws {
        let item = purchase(1234)
        let data = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["account", "assessment", "originalTransactionID", "currency"] { object.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Transaction.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.account, "默认账户")
        XCTAssertEqual(restored.assessment, .unrated)
        XCTAssertEqual(restored.currency, "CNY")
        XCTAssertEqual(restored.amountCents, 1234)
    }
    func testCodableRoundTripAndNoJudgmentWithInsufficientData() throws {
        let input = AppData(transactions: [purchase(100)], monthlyBudgetCents: 5000)
        XCTAssertEqual(try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(input)), input)
        let suggestions = Analytics.suggestions(transactions: [], blocks: [], period: period, budgetCents: 0)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertFalse(suggestions.joined().contains("浪费"))
    }
}


extension LifeCoreTests {
    func testFullwidthReceiptNumbersAreExtracted() {
        let draft = ReceiptParser.parse("实付金额：１２．５０\n商户名称：测试店\n２０２６－１１－１２ １２：３０：００")
        XCTAssertEqual(draft.amountCents, 1250)
        XCTAssertNotNil(draft.date)
        XCTAssertNil(ReceiptParser.parse("实付金额：１２．３４５").amountCents)
    }
    func testFullwidthMoneyInputUsesSameDecimalValidation() {
        XCTAssertEqual(Money.parseCents("１２３．４５"), 12345)
        XCTAssertEqual(Money.parseCents("￥１，２３４．５０元"), 123450)
        XCTAssertNil(Money.parseCents("１２．３４５"))
        XCTAssertNil(Money.parseCents("１２元乱填"))
    }
}
