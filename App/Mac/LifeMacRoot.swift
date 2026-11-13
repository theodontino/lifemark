import SwiftUI
import LifeUI

struct LifeMacRoot: View {
    @State private var importError: String?
    var body: some View {
        Group {
            if let store = LifeIntegrationStore.shared {
                LifeRootView(store: store, capturePanel: AnyView(LifeScreenCapturePanel()), nearbyController: LifeIntegrationStore.nearby)
                    .task { LifeIntegrationStore.nearby?.start(); LifeTimerOverlay.shared.install(); importError = await syncDayflowSummaries() }
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
