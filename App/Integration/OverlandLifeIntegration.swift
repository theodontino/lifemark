#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import CoreLocation
import LifeCore
import LifeStore
import LifeUI

@MainActor
@objc(LifeIntegration)
final class LifeIntegration: NSObject {
    static var captureController: UIViewController?
    private static var nearbyObservers: [NSObjectProtocol] = []
    private static func installNearbySync() {
        guard nearbyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        nearbyObservers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in LifeIntegrationStore.nearby?.start() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in LifeIntegrationStore.nearby?.suspend() }
            }
        ]
        if UIApplication.shared.applicationState == .active { LifeIntegrationStore.nearby?.start() }
    }
    @objc static func installWatchBridge() { PhoneWatchTimerBridge.shared.install() }
    @objc static func setCaptureViewController(_ controller: UIViewController) { captureController = controller }
    @objc static func makeViewController() -> UIViewController {
        installWatchBridge()
        installNearbySync()
        TimerActivityController.shared.install()
        switch LifeIntegrationStore.result {
        case .success(let store):
            return UIHostingController(rootView: LifeRootView(store: store, capturePanel: AnyView(OverlandCapturePanel()), nearbyController: LifeIntegrationStore.nearby))
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
/// The app's own location settings. Overland's tracker runs underneath in visit-only mode;
/// its original settings screens are no longer reachable.
private struct OverlandCapturePanel: View {
    @State private var enabled = GLManager.shared().lifeCaptureEnabled()
    @State private var status = GLManager.shared().locationManager.authorizationStatus
    @State private var places = PlaceBook.load()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Toggle("自动记录去过的地方", isOn: Binding(get: { enabled }, set: { setEnabled($0) }))
        if enabled { statusRow } else {
            Text("开启后，系统会记下你到达和离开一个地方的时间，作为待核对的线索。只记到访，不记路线，耗电很少。").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(places) { place in
            HStack {
                Label(place.name, systemImage: "mappin.and.ellipse")
                Spacer()
                Button("删除", role: .destructive) { places.removeAll { $0.id == place.id }; PlaceBook.save(places) }.buttonStyle(.borderless)
            }
        }
        Text(places.isEmpty ? "在“待核对”里给一次停留的地点起名，之后去同一个地方会自动带上名字。" : "地点的位置只保存在这台手机上，同步出去的只有名字。")
            .font(.callout).foregroundStyle(.secondary)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GLAuthorizationStatusChangedNotification"))) { _ in refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onAppear { refresh() }
    }

    @ViewBuilder private var statusRow: some View {
        switch status {
        case .authorizedAlways:
            Label("已开启。新的到访会出现在“待核对”里。", systemImage: "checkmark.circle").font(.callout)
        case .authorizedWhenInUse:
            Text("现在只有打开人生记录时才能记录。要在后台也记录，请把定位权限改成“始终”。").font(.callout)
            Button("允许始终访问") { GLManager.shared().requestAuthorizationPermission() }
            Button("打开系统设置") { openSettings() }
        case .notDetermined:
            Text("请在弹出的提示里允许使用定位。").font(.callout)
        default:
            Text("定位权限已关闭，无法记录到访。").font(.callout)
            Button("打开系统设置") { openSettings() }
        }
    }

    private func refresh() {
        enabled = GLManager.shared().lifeCaptureEnabled()
        status = GLManager.shared().locationManager.authorizationStatus
        places = PlaceBook.load()
    }
    private func setEnabled(_ value: Bool) {
        if value {
            // Location access is requested here, at the moment the person turns the feature on.
            GLManager.shared().lifeStartVisitCapture()
            GLManager.shared().requestAuthorizationPermission()
        } else {
            GLManager.shared().lifeStopCapture()
        }
        refresh()
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
#endif

