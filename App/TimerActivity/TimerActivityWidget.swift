import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LifeTimerWidgetBundle: WidgetBundle {
    var body: some Widget { LifeTimerWidget() }
}

struct LifeTimerWidget: Widget {
    private let openApp = URL(string: "liferecord://timers")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimeActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "timer").font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.state.title).font(.headline).lineLimit(2)
                    Text(context.state.category).font(.caption).foregroundStyle(.secondary)
                    Text("点击打开应用结束计时").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                elapsed(context.attributes.start)
                    .font(.title2.monospacedDigit().bold())
                    .multilineTextAlignment(.trailing)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.86))
            .activitySystemActionForegroundColor(.mint)
            .foregroundStyle(.white)
            .widgetURL(openApp)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("正在计时", systemImage: "timer").font(.caption).foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsed(context.attributes.start).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title).font(.headline).lineLimit(2)
                        Text("\(context.state.category) · 点击回到应用结束")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.mint)
            } compactTrailing: {
                elapsed(context.attributes.start).monospacedDigit().frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.mint)
            }
            .widgetURL(openApp)
            .keylineTint(.mint)
        }
    }

    private func elapsed(_ start: Date) -> some View {
        Text(start, style: .timer).contentTransition(.numericText())
    }
}
