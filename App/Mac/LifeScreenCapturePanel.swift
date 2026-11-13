import SwiftUI

/// Native settings for the embedded screen recorder. Viewing settings never starts recording.
@MainActor
struct LifeScreenCapturePanel: View {
    @ObservedObject private var module = LifeScreenModule.shared
    @ObservedObject private var overlay = LifeTimerOverlay.shared
    @State private var interval = ScreenshotConfig.interval
    @State private var storageBytes = StoragePreferences.recordingsLimitBytes
    @State private var applications: [RecordingPrivacyApplication] = []
    @State private var blockedIdentifiers = RecordingPrivacyPreferences.blockedApplicationIdentifiers()
    @State private var selectedApplication = ""
    @State private var loadingApplications = true

    private let standardIntervals: [TimeInterval] = [10, 30, 60]
    private let standardLimits: [Int64] = [1_000_000_000, 2_000_000_000, 5_000_000_000]
    private var availableApplications: [RecordingPrivacyApplication] {
        applications.filter { !blockedIdentifiers.contains($0.bundleIdentifier.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("自动记录 Mac 上在做什么", isOn: Binding(get: { module.enabled }, set: { module.setEnabled($0) }))
            Text("开启后会定时截取屏幕，并将抽样截图发送给你在上方配置的 AI 服务，生成待核对的时间线索。需要支持图片输入的模型；云端服务可能收费。默认关闭。").font(.callout).foregroundStyle(.secondary)
            Text("每次开启只分析本次新采集的截图。关闭后不再发起新的分析请求；已经发出的请求可能完成。本机已有记录会保留。").font(.caption).foregroundStyle(.secondary)
            LabeledContent("状态", value: module.status)
            LabeledContent("等待分析", value: "\(module.pendingCount) 批")
            if let lastSuccess = module.lastSuccess {
                LabeledContent("最近完成") { Text(lastSuccess, format: .dateTime.month().day().hour().minute()) }
            }
            if let error = module.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Button("重新检查并重试") { module.retry() }
            }
            Picker("截屏间隔", selection: Binding(get: { interval }, set: { interval = $0; ScreenshotConfig.interval = $0 })) {
                ForEach(standardIntervals, id: \.self) { seconds in Text("每 \(Int(seconds)) 秒").tag(seconds) }
                if !standardIntervals.contains(interval) { Text("原设置：每 \(Int(interval)) 秒").tag(interval) }
            }
            Text("60 秒更省本机空间，但可能漏掉短暂活动。发送给 AI 的图片数量经过抽样，费用不会按采集张数等比例减少。").font(.caption).foregroundStyle(.secondary)
            Picker("截图空间上限", selection: Binding(get: { storageBytes }, set: { bytes in
                storageBytes = bytes
                StorageManager.shared.updateStorageLimit(bytes: bytes)
            })) {
                ForEach(standardLimits, id: \.self) { bytes in Text("\(bytes / 1_000_000_000) GB").tag(bytes) }
                if !standardLimits.contains(storageBytes) {
                    Text("原设置：" + ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .decimal)).tag(storageBytes)
                }
            }
            Text("达到上限会清理较旧的屏幕截图；调低上限可能立即开始清理。已经导入人生记录的事项会保留。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("不记录的软件 · \(blockedIdentifiers.count) 个") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("这些软件在前台时暂停截图，它们的窗口也会从截图中排除。其他软件里的敏感内容仍可能被记录。").font(.caption).foregroundStyle(.secondary)
                    ForEach(blockedIdentifiers, id: \.self) { identifier in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(applicationName(identifier))
                                Text(identifier).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("移出排除名单") { saveBlocked(blockedIdentifiers.filter { $0 != identifier }) }
                        }
                    }
                    if loadingApplications { ProgressView("正在读取已安装软件…") }
                    else if availableApplications.isEmpty { Text("没有其他可添加的软件。").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Picker("添加软件", selection: $selectedApplication) {
                            Text("请选择软件").tag("")
                            ForEach(availableApplications) { app in Text(app.name).tag(app.bundleIdentifier) }
                        }
                        Button("加入排除名单") {
                            saveBlocked(blockedIdentifiers + [selectedApplication])
                            selectedApplication = ""
                        }.disabled(selectedApplication.isEmpty)
                    }
                }.padding(.top, 6)
            }
            Divider()
            Picker("计时条的位置", selection: $overlay.usesIsland) {
                Text("贴在刘海两侧（会盖住刘海旁的一小段菜单栏）").tag(true)
                Text("挂在菜单栏下面（不遮挡菜单栏）").tag(false)
            }
        }
        .task {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: ScreenshotConfig.intervalKey) == nil { ScreenshotConfig.interval = 60 }
            if defaults.object(forKey: "storageLimitRecordingsBytes") == nil { StoragePreferences.recordingsLimitBytes = 2_000_000_000 }
            interval = ScreenshotConfig.interval
            storageBytes = StoragePreferences.recordingsLimitBytes
            let installed = await Task.detached(priority: .utility) { RecordingPrivacyPreferences.installedApplications() }.value
            guard !Task.isCancelled else { return }
            applications = installed
            RecordingPrivacyPreferences.seedDefaultSecretApplicationsIfNeeded(from: installed)
            blockedIdentifiers = RecordingPrivacyPreferences.blockedApplicationIdentifiers()
            loadingApplications = false
            module.refresh()
        }
    }

    private func applicationName(_ identifier: String) -> String {
        applications.first { $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }?.name ?? identifier
    }
    private func saveBlocked(_ identifiers: [String]) {
        RecordingPrivacyPreferences.saveBlockedApplicationIdentifiers(identifiers)
        blockedIdentifiers = RecordingPrivacyPreferences.blockedApplicationIdentifiers()
    }
}
