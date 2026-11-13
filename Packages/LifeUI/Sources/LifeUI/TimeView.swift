import SwiftUI
import LifeCore
import LifeStore

/// Records and review of time in one place: a day's timeline, or a week / month summary.
@MainActor struct TimeView: View {
    let store: LifeStore
    @State private var date = Date()
    @State private var range = 0
    @State private var editing: TimeBlock?
    private let calendar = Calendar.current
    private var unit: Calendar.Component { range == 1 ? .weekOfYear : range == 2 ? .month : .day }
    private var period: DateInterval { calendar.dateInterval(of: unit, for: date) ?? dayInterval(date) }
    private var rows: [TimeBlock] { store.timeBlocks.filter { $0.start < period.end && $0.end > period.start }.sorted { $0.start < $1.start } }
    private var label: String {
        switch range {
        case 1: return periodLabel(period)
        case 2: return "\(calendar.component(.year, from: date))年\(calendar.component(.month, from: date))月"
        default: return monthDay(date) + " " + weekdayText(date)
        }
    }
    private var unitName: String { ["天", "周", "月"][range] }

    var body: some View {
        let summary = Analytics.time(store.timeBlocks, in: period)
        PageScroll {
            PageHeader("时间") {
                Picker("范围", selection: $range) { Text("日").tag(0); Text("周").tag(1); Text("月").tag(2) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().frame(minHeight: controlHeight)
                PeriodNav(label: label, previousLabel: "前一" + unitName, nextLabel: "后一" + unitName,
                          previous: { step(-1) }, next: { step(1) })
                if !calendar.isDateInToday(date) { Button("回到今天") { date = Date() }.buttonStyle(.lifeSecondary) }
                Button { editing = newBlock() } label: { Label("补记", systemImage: "plus") }.buttonStyle(.lifePrimary)
            }
            FlowLayout(spacing: 24) {
                BigFigure(value: durationText(summary.occupiedSeconds), caption: "已记录")
                if summary.overlapSeconds >= 60 {
                    Text("其中 \(durationText(summary.overlapSeconds)) 同时做两件事").foregroundStyle(.secondary).frame(minHeight: 40, alignment: .bottom)
                }
            }
            TwoColumns {
                if range == 0 { dayColumn } else { daysColumn }
            } right: {
                categoryPanel(summary)
                durationPanel
            }
        }.sheet(item: $editing) { TimeEditor(store: store, initial: $0) }
    }

    private func step(_ value: Int) { date = calendar.date(byAdding: unit, value: value, to: date) ?? date }
    private func newBlock() -> TimeBlock {
        if calendar.isDateInToday(date) { return .init(title: "", category: "工作", start: Date().addingTimeInterval(-1800), end: Date()) }
        let day = range == 0 ? date : period.start
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        return .init(title: "", category: "工作", start: start, end: start.addingTimeInterval(3600))
    }

    // MARK: Day

    @ViewBuilder private var dayColumn: some View {
        let running = calendar.isDateInToday(date) ? store.runningTimers : []
        if rows.isEmpty && running.isEmpty {
            Panel { EmptyRecords(title: "这一天还没有记录", detail: "空白表示没有记录，不代表在休息。", icon: "calendar") }
        } else {
            Panel("时间线") {
                DayTimeline(blocks: rows, running: running, period: period) { editing = $0 }
                Text("空白时段表示没有记录，不代表在休息。").font(.callout).foregroundStyle(.secondary)
            }
            if !rows.isEmpty {
                Panel("全部事项 · \(rows.count)") { RowList(items: rows, action: { editing = $0 }) { TimeLine(block: $0) } }
            }
        }
    }

    // MARK: Week and month

    @ViewBuilder private var daysColumn: some View {
        let days = stride(from: period.start, to: period.end, by: 86400).map { dayInterval($0.addingTimeInterval(3600)) }
        let totals = days.map { Analytics.time(store.timeBlocks, in: $0).occupiedSeconds }
        let peak = max(totals.max() ?? 0, 1)
        if rows.isEmpty {
            Panel { EmptyRecords(title: "这段时间还没有记录", detail: "空白表示没有记录，不代表在休息。", icon: "calendar") }
        } else {
            Panel("每天记录了多久") {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    Button { date = day.start; range = 0 } label: {
                        BarRow(label: monthDay(day.start) + " " + weekdayText(day.start),
                               value: totals[index] > 0 ? durationText(totals[index]) : "没有记录", fraction: totals[index] / peak)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("查看这一天")
                }
            }
        }
    }

    // MARK: Review panels

    private func categoryPanel(_ summary: TimeSummary) -> some View {
        let values = summary.categorySeconds.sorted { $0.value > $1.value }
        let peak = max(values.first?.value ?? 0, 1)
        return Panel("各类用时") {
            if values.isEmpty { Text("确认记录后显示。").foregroundStyle(.secondary) }
            ForEach(values, id: \.key) { entry in
                BarRow(label: entry.key, value: durationText(entry.value), fraction: entry.value / peak, color: timeCategoryColor(entry.key))
            }
        }
    }
    private var durationPanel: some View {
        // A single day has too few samples, so the day view looks back 30 days.
        let window = range == 0 ? DateInterval(start: period.end.addingTimeInterval(-30 * 86400), end: period.end) : period
        let tasks = ReviewAnalytics.taskDurations(blocks: store.timeBlocks, period: window)
        return Panel("同一件事通常多久") {
            if tasks.isEmpty { Text("相同名称的事项会放在一起统计。").foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(Array(tasks.prefix(8).enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Rectangle().fill(lifeLine).frame(height: 1) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).fontWeight(.semibold).lineLimit(1)
                            Text("\(task.count) 次 · 平均 \(durationText(task.averageSeconds))").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("通常 " + durationText(task.medianSeconds)).monospacedDigit()
                    }.frame(minHeight: 48)
                }
            }
            if !tasks.isEmpty { Text(range == 0 ? "按最近 30 天已确认的记录统计。" : "按这段时间已确认的记录统计。").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// A day drawn against hour lines; overlapping records sit in side-by-side lanes.
struct DayTimeline: View {
    let blocks: [TimeBlock]
    let running: [RunningTimer]
    let period: DateInterval
    let open: (TimeBlock) -> Void
    private let hourHeight: CGFloat = 46, minimumHeight: CGFloat = 24

    private struct Entry: Identifiable {
        let id: UUID, title: String, category: String, start: Date, end: Date
        let block: TimeBlock?, pending: Bool
        var lane = 0, top: CGFloat = 0, height: CGFloat = 0
    }
    private struct Plan { var entries: [Entry]; var lanes: Int; var firstHour: Int; var hours: Int }

    private func layout(now: Date) -> Plan {
        var entries = blocks.map { Entry(id: $0.id, title: $0.title, category: $0.category, start: max($0.start, period.start), end: min($0.end, period.end), block: $0, pending: $0.status == .pending) }
        entries += running.map { Entry(id: $0.id, title: $0.title, category: $0.category, start: max($0.start, period.start), end: min(max(now, $0.start.addingTimeInterval(60)), period.end), block: nil, pending: false) }
        entries.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        let calendar = Calendar.current
        let earliest = entries.map(\.start).min() ?? period.start, latest = entries.map(\.end).max() ?? period.end
        let firstHour = calendar.component(.hour, from: earliest)
        let base = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: earliest) ?? earliest
        let hours = max(1, Int((latest.timeIntervalSince(base) / 3600).rounded(.up)))
        var laneBottoms: [CGFloat] = []
        for index in entries.indices {
            let top = CGFloat(entries[index].start.timeIntervalSince(base) / 3600) * hourHeight
            let height = max(minimumHeight, CGFloat(entries[index].end.timeIntervalSince(entries[index].start) / 3600) * hourHeight)
            // Lanes are chosen from drawn heights, so two short neighbours never cover each other.
            let lane = laneBottoms.firstIndex { $0 + 2 <= top } ?? laneBottoms.count
            if lane == laneBottoms.count { laneBottoms.append(0) }
            laneBottoms[lane] = top + height
            entries[index].lane = lane; entries[index].top = top; entries[index].height = height
        }
        return Plan(entries: entries, lanes: max(1, laneBottoms.count), firstHour: firstHour, hours: hours)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: running.isEmpty ? 3600 : 60)) { context in
            let plan = layout(now: context.date)
            let total = max(CGFloat(plan.hours) * hourHeight, (plan.entries.map { $0.top + $0.height }.max() ?? 0)) + 8
            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ForEach(0...plan.hours, id: \.self) { hour in
                        Text(String(format: "%02d:00", (plan.firstHour + hour) % 24)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .offset(y: CGFloat(hour) * hourHeight - 7)
                    }
                }.frame(width: 42, height: total, alignment: .topLeading).accessibilityHidden(true)
                GeometryReader { geometry in
                    let laneWidth = max(96, (geometry.size.width - CGFloat(plan.lanes - 1) * 6) / CGFloat(plan.lanes))
                    let needed = CGFloat(plan.lanes) * (laneWidth + 6) - 6
                    ScrollView(.horizontal, showsIndicators: needed > geometry.size.width + 1) {
                    ZStack(alignment: .topLeading) {
                        ForEach(0...plan.hours, id: \.self) { hour in
                            Rectangle().fill(lifeLine).frame(height: 1).offset(y: CGFloat(hour) * hourHeight)
                        }
                        ForEach(plan.entries) { entry in
                            card(entry).frame(width: laneWidth, height: entry.height)
                                .offset(x: CGFloat(entry.lane) * (laneWidth + 6), y: entry.top)
                        }
                    }.frame(width: max(needed, geometry.size.width), height: total, alignment: .topLeading)
                    }.scrollDisabled(needed <= geometry.size.width + 1)
                }.frame(height: total)
            }.padding(.top, 8)
        }
    }

    @ViewBuilder private func card(_ entry: Entry) -> some View {
        let color = timeCategoryColor(entry.category)
        let face = VStack(alignment: .leading, spacing: 0) {
            Text(entry.title).font(.callout.weight(.semibold)).lineLimit(1)
            if entry.height >= 40 {
                Text(entry.block == nil ? hourMinute(entry.start) + " 起 · 计时中" : hourMinute(entry.start) + " – " + hourMinute(entry.end))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(entry.block == nil ? 0.12 : 0.26), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(entry.pending ? lifeWarnText : color,
                                                          style: StrokeStyle(lineWidth: 1, dash: entry.block == nil || entry.pending ? [4, 3] : [])))
        .clipped().contentShape(Rectangle())
        if let block = entry.block {
            Button { open(block) } label: { face }.buttonStyle(.plain)
                .accessibilityLabel("\(entry.title)，\(hourMinute(entry.start)) 到 \(hourMinute(entry.end))\(entry.pending ? "，待核对" : "")")
        } else {
            face.accessibilityLabel("\(entry.title)，正在计时")
        }
    }
}
