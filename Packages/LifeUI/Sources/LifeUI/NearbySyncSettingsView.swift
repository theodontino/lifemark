import SwiftUI
import LifeNearby
#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
#elseif os(iOS)
import AVFoundation
import UIKit
#endif

/// Lives inside the existing settings form; nearby access starts only after enabling it.
@MainActor struct NearbySyncSettingsView: View {
    @Bindable var controller: NearbySyncController
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairingText = ""
    @State private var removingPeer: NearbyPeer?
    #if os(iOS)
    @State private var scanning = false
    #endif

    var body: some View {
        Section("附近设备同步") {
            Toggle("在 Mac 和 iPhone 之间同步", isOn: $controller.enabled)
            if controller.enabled {
                LabeledContent("状态", value: controller.state)
                if let request = controller.pairingRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("要和“\(request.displayName)”配对吗？").font(.headline)
                        Text(request.remoteConfirmed ? "对方已确认。" : "两边都确认后才开始同步。请确认这是你自己的设备。").font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("取消") { controller.cancelPairing() }.buttonStyle(.lifeSecondary)
                            Button(request.localConfirmed ? "已确认，等待对方" : "确认配对") { controller.confirmPairing() }
                                .buttonStyle(.lifePrimary).disabled(request.localConfirmed)
                        }
                    }.padding(.vertical, 6)
                }
                ForEach(controller.peers) { peer in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName).fontWeight(.semibold)
                            Text(peer.isConnected ? "已连接" : (peer.lastSeen.map { "上次连接 " + monthDay($0) + " " + hourMinute($0) } ?? "未连接"))
                                .font(.callout).foregroundStyle(peer.isConnected ? lifeAccentText : Color.secondary)
                        }
                        Spacer()
                        Button("解除配对") { removingPeer = peer }.buttonStyle(LifeButtonStyle(kind: .danger, compact: true))
                    }.padding(.vertical, 4)
                }
                if !controller.peers.isEmpty {
                    LabeledContent("上次同步完成", value: controller.lastSuccess.map { relativeDay($0) + " " + hourMinute($0) } ?? "还没有")
                    Button("立即同步") { controller.syncNow() }.buttonStyle(LifeButtonStyle(compact: true))
                }
                pairingControls
                Text("AI 的接口地址、模型和密钥也会在已配对的设备之间同步，以最近修改的为准。“允许调用 AI”的开关每台设备各自决定。").font(.callout).foregroundStyle(.secondary)
                #if os(iOS)
                Text("iPhone 切到后台时暂停同步，回到前台自动补齐。").font(.callout).foregroundStyle(.secondary)
                #endif
            } else {
                Text("两台设备在同一个 Wi‑Fi 下并且都打开人生记录时自动同步。只和你确认过的设备同步，关闭后本机记录不受影响。").font(.callout).foregroundStyle(.secondary)
            }
            ErrorText(text: controller.errorMessage)
        }
        .confirmationDialog("解除与这台设备的配对？", isPresented: Binding(get: { removingPeer != nil }, set: { if !$0 { removingPeer = nil } }), titleVisibility: .visible, presenting: removingPeer) { peer in
            Button("解除与 \(peer.displayName) 的配对", role: .destructive) { controller.removePeer(peer.id); removingPeer = nil }
        } message: { _ in Text("将停止与这台设备同步，已有本机记录会保留。") }
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            NearbyQRCodeScanner { code in
                scanning = false
                pairingText = code
                controller.acceptPairingCode(code)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { scanning = false } }
        .onChange(of: controller.enabled) { _, enabled in if !enabled { scanning = false } }
        #endif
    }

    @ViewBuilder private var pairingControls: some View {
        #if os(macOS)
        Button(controller.peers.isEmpty ? "配对 iPhone：显示二维码" : "配对另一台 iPhone") { controller.createPairingCode() }.buttonStyle(LifeButtonStyle(compact: true))
        if let code = controller.pairingCode, let expires = controller.pairingExpiresAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date < expires {
                    let left = max(0, Int(expires.timeIntervalSince(context.date)))
                    VStack(alignment: .leading, spacing: 8) {
                        if let image = qrImage(code) {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220).padding(10).background(.white)
                                .accessibilityLabel("配对二维码")
                        }
                        Text("在 iPhone 的 设置 → 附近设备同步 里点“扫描 Mac 上的二维码”。").font(.callout)
                        Text("\(left / 60):\(String(format: "%02d", left % 60)) 后失效。只给你自己的设备扫。").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        DisclosureGroup("扫不了？改用文字配对") { Text(code).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                } else { Text("二维码已失效，请重新显示。").font(.callout).foregroundStyle(.secondary) }
            }
        }
        #elseif os(iOS)
        Button { scanning = true } label: { Label("扫描 Mac 上的二维码", systemImage: "qrcode.viewfinder") }.buttonStyle(LifeButtonStyle(kind: controller.peers.isEmpty ? .primary : .secondary))
        DisclosureGroup("扫不了？粘贴配对文字") {
            TextEditor(text: $pairingText).font(.caption.monospaced()).frame(minHeight: 75)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(lifeFieldLine, lineWidth: 1)).accessibilityLabel("配对文字")
            Button("开始配对") { controller.acceptPairingCode(pairingText.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .buttonStyle(.lifeSecondary).disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        #endif
    }
    #if os(macOS)
    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
    }
    #endif
}

#if os(iOS)
@MainActor private struct NearbyQRCodeScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var permissionGranted = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if permissionGranted {
                    CameraQRCodeView(onCode: onCode, onError: { message = $0 })
                        .frame(minHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                    Text("对准 Mac 设置页里的配对二维码。").font(.callout)
                } else if message == nil { ProgressView("正在检查相机权限…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                Button("改用粘贴配对文字") { dismiss() }.buttonStyle(.lifeSecondary)
            }.padding().navigationTitle("扫描配对二维码")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .task { await requestCamera() }
        }
    }
    private func requestCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        else { allowed = status == .authorized }
        if allowed { permissionGranted = true }
        else { message = "相机权限未开启。可在系统设置中允许访问相机，也可以返回后手动粘贴配对内容。" }
    }
}

@MainActor private struct CameraQRCodeView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> QRCodeCameraController {
        QRCodeCameraController(onCode: onCode, onError: onError)
    }
    func updateUIViewController(_ controller: QRCodeCameraController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRCodeCameraController, coordinator: ()) { controller.stop() }
}

/// The preview is a layer-backed view, so it always matches the view's size.
private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

@MainActor private final class QRCodeCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "LifeRecord.QRScanner")
    private let previewView = CameraPreviewView()
    private var configured = false
    private var delivered = false
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { previewView.backgroundColor = .black; view = previewView }
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else {
            onError("此设备没有可用相机。请返回设置，手动粘贴配对内容。"); return
        }
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); onError("相机暂时不可用，请返回后手动粘贴配对内容。"); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { session.commitConfiguration(); onError("相机暂时不可用，请返回后手动粘贴配对内容。"); return }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { session.commitConfiguration(); onError("相机不支持二维码识别，请使用手动粘贴。"); return }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        previewView.previewLayer.session = session
        previewView.previewLayer.videoGravity = .resizeAspectFill
        configured = true
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard configured else { return }
        let captureSession = session
        sessionQueue.async { if !captureSession.isRunning { captureSession.startRunning() } }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let connection = previewView.previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
    func stop() { let captureSession = session; sessionQueue.async { if captureSession.isRunning { captureSession.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); onCode(code)
    }
}
#endif
