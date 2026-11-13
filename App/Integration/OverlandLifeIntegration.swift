#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import LifeCore
import LifeStore
import LifeUI

@MainActor
@objc(LifeIntegration)
final class LifeIntegration: NSObject {
    static var captureController: UIViewController?
    @objc static func installWatchBridge() { PhoneWatchTimerBridge.shared.install() }
    @objc static func setCaptureViewController(_ controller: UIViewController) { captureController = controller }
    @objc static func makeViewController() -> UIViewController {
        installWatchBridge()
        TimerActivityController.shared.install()
        switch LifeIntegrationStore.result {
        case .success(let store):
            return UIHostingController(rootView: LifeRootView(store: store, capturePanel: AnyView(OverlandCapturePanel())))
        case .failure:
            return UIHostingController(rootView:
                ContentUnavailableView("无法打开生活记录", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(LifeIntegrationStore.openingError ?? "未知错误")))
        }
    }
    /// Completion acknowledges a committed local transaction, independently of CloudKit upload.
    @objc(importLocationFeatures:completion:)
    nonisolated static func importLocationFeatures(_ data: Data, completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            do { try LifeIntegrationStore.result.get().importLocationFeatures(data); completion(nil) }
            catch { completion(error as NSError) }
        }
    }
}
private struct OverlandCapturePanel: View {
    @State private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("打开定位采集设置") { showing = true }
            Text("采集需主动开启。采集界面暂沿用原定位器，部分为英文；本机地点线索会进入待核对区。").font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $showing) {
            NavigationStack {
                OverlandCaptureController()
                    .navigationTitle("定位采集")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showing = false } } }
            }
        }
    }
}
private struct OverlandCaptureController: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { LifeIntegration.captureController ?? UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif

