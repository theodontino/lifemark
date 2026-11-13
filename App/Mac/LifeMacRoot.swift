import SwiftUI
import LifeUI

struct LifeMacRoot: View {
    @State private var importError: String?
    var body: some View {
        Group {
            if let store = LifeIntegrationStore.shared {
                LifeRootView(store: store, capturePanel: AnyView(LifeMacCapturePanel()))
                    .task { LifeTimerOverlay.shared.install(); importError = await syncDayflowSummaries() }
                    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { _ in
                        Task { importError = await syncDayflowSummaries() }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let importError { Text(importError).font(.caption).foregroundStyle(.red).padding(8) }
                    }
            } else {
                ContentUnavailableView("无法打开记录", systemImage: "externaldrive.badge.exclamationmark", description: Text(LifeIntegrationStore.openingError ?? "未知错误"))
            }
        }
    }
}
struct LifeMacCapturePanel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var state = AppState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(state.isRecording ? "正在生成屏幕线索" : "屏幕记录已暂停", systemImage: state.isRecording ? "record.circle" : "pause.circle")
            Button("打开屏幕记录与模型设置") { openWindow(id: "main") }
            if state.isRecording {
                Button("暂停屏幕记录") { AppState.shared.setRecording(false, analyticsReason: "manual", persistPreference: true) }
            }
            Text("请在屏幕设置中完成权限和模型配置，再主动开启记录。新线索先进入待核对区；录屏不会放进 iCloud。原采集设置部分为英文。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

