import Foundation
import Combine
import AppKit
import LifeUI

/// Read at every request, including retries and the second text-only analysis stage.
enum LifeScreenAnalysisPolicy {
    static var sessionID: String { UserDefaults.standard.string(forKey: "life.screen.sessionID") ?? "" }
    static var sessionStart: Int { UserDefaults.standard.integer(forKey: "life.screen.sessionStart") }
    static func configuration() -> OpenAICompatibleConfiguration? {
        let d = UserDefaults.standard
        let base = (d.string(forKey: "life.ai.baseURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (d.string(forKey: "life.ai.model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let url = URL(string: base), let host = url.host,
              url.user == nil, url.password == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
        let config = OpenAICompatibleConfiguration(preset: .custom, baseURL: base, modelID: model)
        return config.isComplete ? config : nil
    }
    static func isAllowed() -> Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: "life.screen.sessionEnabled") && d.bool(forKey: "life.ai.enabled") && configuration() != nil
    }
    static func requestAllowed(_ config: OpenAICompatibleRuntimeConfiguration, sessionID: String? = nil) -> Bool {
        if let sessionID, sessionID != Self.sessionID { return false }
        guard isAllowed(), let current = configuration(), let key = try? LifeAIConfiguration.readAPIKey() else { return false }
        return current.baseURL == config.endpoint && current.modelID == config.modelID && key.trimmingCharacters(in: .whitespacesAndNewlines) == (config.bearerToken ?? "")
    }
}

@MainActor final class LifeScreenModule: ObservableObject {
    static let shared = LifeScreenModule()
    @Published private(set) var enabled = false
    @Published private(set) var status = "屏幕记录已关闭"
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSuccess: Date?
    private var installed = false
    private var starting = false
    private var retrying = false
    private var generation = 0
    private var subscriptions = Set<AnyCancellable>()
    private var poll: Timer?
    private var completedIDs = Set<Int64>()

    func install() {
        guard !installed else { return }; installed = true
        let d = UserDefaults.standard
        d.set(false, forKey: "life.screen.sessionEnabled")
        d.set(false, forKey: AccessibilityCaptureConfig.enabledKey)
        if d.object(forKey: ScreenshotConfig.intervalKey) == nil { ScreenshotConfig.interval = 60 }
        if d.object(forKey: "storageLimitRecordingsBytes") == nil { StoragePreferences.recordingsLimitBytes = 2_000_000_000 }
        completedIDs = Set(StorageManager.shared.allBatches().filter { $0.status == "completed" }.map(\.id))
        lastSuccess = d.object(forKey: "life.screen.lastSuccess") as? Date
        migrateConfiguration()
        configureCategories()
        NotificationCenter.default.publisher(for: LifeAIConfiguration.didChange).sink { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }.store(in: &subscriptions)
        AppState.shared.$isRecording.dropFirst().removeDuplicates().sink { [weak self] recording in
            Task { @MainActor in
                guard let self, !recording, self.enabled else { return }
                self.setEnabled(false)
            }
        }.store(in: &subscriptions)
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func setEnabled(_ value: Bool) {
        install(); if value && starting { return }; generation += 1
        if !value {
            starting = false; enabled = false
            UserDefaults.standard.set(false, forKey: "life.screen.sessionEnabled")
            AnalysisManager.shared.stopAnalysisJob()
            RecordingControl.stop(reason: "life_screen_disabled")
            status = "屏幕记录已关闭；在途请求可能完成"
            return
        }
        guard !starting else { return }
        guard UserDefaults.standard.bool(forKey: "life.ai.enabled"), LifeScreenAnalysisPolicy.configuration() != nil else {
            errorMessage = "请先在上方允许调用 AI，并填写 HTTPS 服务地址和支持图片的模型。"; return
        }
        do { _ = try LifeAIConfiguration.readAPIKey() } catch { errorMessage = error.localizedDescription; return }
        guard ScreenRecordingPermissionNotice.isGranted else {
            errorMessage = "需要屏幕录制权限。请在系统设置允许人生记录录屏，再回来开启。"
            ScreenRecordingPermissionNotice.post(reason: "life_screen_enable")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            return
        }
        starting = true; status = "正在准备软件排除名单…"
        let attempt = generation
        Task {
            let apps = await Task.detached(priority: .utility) { RecordingPrivacyPreferences.installedApplications() }.value
            guard attempt == generation, starting else { return }
            RecordingPrivacyPreferences.seedDefaultSecretApplicationsIfNeeded(from: apps)
            guard ScreenRecordingPermissionNotice.isGranted,
                  UserDefaults.standard.bool(forKey: "life.ai.enabled"), LifeScreenAnalysisPolicy.configuration() != nil else {
                starting = false; status = "屏幕记录未开启"; errorMessage = "权限或 AI 设置已改变，请核对后重新开启。"; return
            }
            do {
                _ = try LifeAIConfiguration.readAPIKey()
                try LLMProviderRoutingStore.save(LLMProviderRouting(primary: .openAICompatible))
                LLMOutputLanguagePreferences.override = "Simplified Chinese"
                UserDefaults.standard.set(Int(ceil(Date().timeIntervalSince1970)), forKey: "life.screen.sessionStart")
                UserDefaults.standard.set(UUID().uuidString, forKey: "life.screen.sessionID")
                UserDefaults.standard.set(true, forKey: "life.screen.sessionEnabled")
                enabled = true; starting = false; errorMessage = nil
                PauseManager.shared.clearPauseState()
                AppState.shared.setRecording(true, analyticsReason: "life_screen_enabled")
                AnalysisManager.shared.startAnalysisJob(); refresh()
            } catch { starting = false; errorMessage = error.localizedDescription; status = "屏幕记录未开启" }
        }
    }
    func retry() {
        guard enabled, LifeScreenAnalysisPolicy.isAllowed() else { errorMessage = "请先开启屏幕记录。"; return }
        guard !retrying else { return }
        let ids = StorageManager.shared.allBatches().filter {
            $0.start >= LifeScreenAnalysisPolicy.sessionStart && $0.status == "failed" && !AnalysisManager.shared.isBatchInFlight($0.id)
        }.map(\.id)
        guard !ids.isEmpty else { AnalysisManager.shared.triggerAnalysisNow(); return }
        retrying = true; errorMessage = nil
        let admittedSession = LifeScreenAnalysisPolicy.sessionID
        AnalysisManager.shared.setManualRetryRunning(true)
        Task {
            defer { retrying = false; AnalysisManager.shared.setManualRetryRunning(false); refresh() }
            for id in ids {
                guard enabled, admittedSession == LifeScreenAnalysisPolicy.sessionID else { break }
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        AnalysisManager.shared.reprocessBatch(id, stepHandler: { _ in }, completion: { continuation.resume(with: $0) })
                    }
                } catch {
                    if enabled, admittedSession == LifeScreenAnalysisPolicy.sessionID { errorMessage = error.localizedDescription }
                    break
                }
            }
        }
    }
    private func configurationChanged() {
        if enabled || starting {
            setEnabled(false)
            errorMessage = "AI 设置已改变，屏幕记录已暂停。核对配置后请重新开启。"
        }
    }
    func refresh() {
        let batches = StorageManager.shared.allBatches().filter { $0.start >= LifeScreenAnalysisPolicy.sessionStart }
        pendingCount = batches.filter { ["pending", "processing"].contains($0.status) }.count
        let completed = Set(batches.filter { $0.status == "completed" }.map(\.id))
        if !completed.subtracting(completedIDs).isEmpty {
            lastSuccess = Date(); UserDefaults.standard.set(lastSuccess, forKey: "life.screen.lastSuccess")
        }
        completedIDs.formUnion(completed)
        guard enabled else { return }
        if batches.contains(where: { $0.status.hasPrefix("failed") }) {
            status = "部分分析失败 · 本机截图已保留"
            errorMessage = "请检查模型是否支持图片、服务地址、密钥或余额。可重试本次开启后产生的失败批次。"
        } else { status = pendingCount > 0 ? "正在采集并分析 · 线索进入待核对" : "正在采集 · 等待形成约 15 分钟的分析批次" }
    }
    private func migrateConfiguration() {
        let d = UserDefaults.standard
        guard (d.string(forKey: "life.ai.baseURL") ?? "").isEmpty, (d.string(forKey: "life.ai.model") ?? "").isEmpty,
              let old = OpenAICompatiblePreferences.load() else { return }
        do {
            if try LifeAIConfiguration.readAPIKey().isEmpty, let key = KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) {
                try LifeAIConfiguration.saveAPIKey(key)
            }
            d.set(old.baseURL, forKey: "life.ai.baseURL"); d.set(old.modelID, forKey: "life.ai.model")
        } catch { errorMessage = "旧 AI 配置未迁移：" + error.localizedDescription }
    }
    private func configureCategories() {
        let store = CategoryStore.shared
        let names = ["工作", "学习", "创作", "通勤", "生活", "娱乐", "休息", "待分类"]
        let aliases = ["Work": "工作", "Personal": "生活", "Distraction": "娱乐"]
        for category in store.editableCategories {
            if let name = aliases[category.name], !store.categories.contains(where: { $0.name == name }) { store.renameCategory(id: category.id, to: name) }
        }
        for name in names {
            if !store.categories.contains(where: { $0.name == name }) { store.addCategory(name: name) }
            if let category = store.categories.first(where: { $0.name == name }), category.details.isEmpty {
                store.updateDetails("根据屏幕证据判断是否属于“\(name)”；无法确定时使用待分类。", for: category.id)
            }
        }
    }
}
