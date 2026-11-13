import AVFoundation
import AppKit
import Speech
import SwiftUI

// Experimental voice diary, Mac only.
//
// The microphone is recorded in short AAC segments; each sealed segment is transcribed on this
// Mac with Apple's SpeechTranscriber. Audio and text stay in Application Support and are not
// synced, uploaded or turned into time records. Off at every launch.

struct VoiceSegment: Codable, Identifiable, Equatable {
    enum State: String, Codable { case waiting, done, silent, failed }
    var id = UUID()
    var start: Date
    var duration: TimeInterval
    var fileName: String
    var state: State = .waiting
    var text = ""
    var error: String?
    var audioDeleted = false
}

private struct VoiceError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Writes the microphone to 16 kHz mono AAC files, sealing one every `segmentLength` seconds.
private final class VoiceRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let directory: URL
    private let segmentLength: TimeInterval
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceRecorder.sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var segmentStart: Date?
    private var frames: Int64 = 0
    private var running = false
    var onSegment: (@Sendable (URL, Date, TimeInterval) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    init(directory: URL, segmentLength: TimeInterval) { self.directory = directory; self.segmentLength = segmentLength }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("没有找到可用的麦克风。") }
        input.removeTap(onBus: 0)
        lock.lock(); running = true; converter = nil; lock.unlock()
        // Conversion and writing happen inside the tap: the buffer is only valid during the callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.handle(buffer) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); running = false; seal(); lock.unlock()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard running, buffer.frameLength > 0 else { return }
        do {
            if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
            guard let converter else { throw VoiceError("无法转换麦克风的音频格式。") }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                if consumed { inputStatus.pointee = .noDataNow; return nil }
                consumed = true; inputStatus.pointee = .haveData; return buffer
            }
            if status == .error { throw failure ?? VoiceError("音频转换失败。") }
            guard output.frameLength > 0 else { return }
            if file == nil { try open() }
            try file?.write(from: output)
            frames += Int64(output.frameLength)
            if Double(frames) / Self.sampleRate >= segmentLength { seal() }
        } catch {
            running = false; seal()
            onError?(error.localizedDescription)
        }
    }

    private func open() throws {
        let start = Date()
        let url = directory.appendingPathComponent("voice-\(Int(start.timeIntervalSince1970 * 1000)).m4a")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        fileURL = url; segmentStart = start; frames = 0
    }

    /// Caller holds the lock. Releasing the AVAudioFile finalizes the container.
    private func seal() {
        guard let url = fileURL, let start = segmentStart else { return }
        let duration = Double(frames) / Self.sampleRate
        file = nil; fileURL = nil; segmentStart = nil; frames = 0
        if duration < 1 { try? FileManager.default.removeItem(at: url) } else { onSegment?(url, start, duration) }
    }
}

@available(macOS 26.0, *)
private enum VoiceTranscription {
    static func text(of url: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw VoiceError("这台 Mac 不支持本机语音转写。") }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "zh_CN"), preset: .transcription)
        // The detector lets the analyzer skip stretches without speech.
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)
        // Never download a model silently: say so and let the person decide.
        if try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) != nil {
            throw VoiceError("这台 Mac 还没有安装中文语音模型。请在 系统设置 → 键盘 → 听写 里添加普通话后重试。")
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        async let collected = collect(transcriber)
        do {
            if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
            return try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as NSError where error.domain == "SFSpeechErrorDomain" && error.code == 1 {
            // "RecogRejected": with the speech detector attached, a segment in which nobody speaks
            // ends this way instead of with an empty result. It is silence, not a failure.
            return ""
        }
    }
    private static func collect(_ transcriber: SpeechTranscriber) async throws -> String {
        var output = ""
        for try await result in transcriber.results { output += String(result.text.characters) }
        return output
    }
}

@MainActor final class LifeVoiceExperiment: ObservableObject {
    static let shared = LifeVoiceExperiment()
    static let segmentLength: TimeInterval = 120
    static let audioLimitBytes: Int64 = 1_000_000_000
    static let audioRetention: TimeInterval = 72 * 3600

    @Published private(set) var enabled = false
    @Published private(set) var status = "已关闭"
    @Published private(set) var segments: [VoiceSegment] = []
    @Published private(set) var audioBytes: Int64 = 0
    @Published private(set) var errorMessage: String?
    let directory: URL
    private var recorder: VoiceRecorder?
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("LifeRecord/VoiceExperiment", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([VoiceSegment].self, from: data) { segments = saved }
        measure()
    }

    var waitingCount: Int { segments.filter { $0.state == .waiting }.count }

    func setEnabled(_ value: Bool) {
        if value { Task { await begin() } } else { end(status: "已关闭") }
    }

    private func begin() async {
        guard !enabled else { return }
        errorMessage = nil
        guard #available(macOS 26.0, *) else { errorMessage = "需要 macOS 26 或更新的系统才能在本机转写。"; return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else { errorMessage = "没有麦克风权限。请在 系统设置 → 隐私与安全性 → 麦克风 里允许人生记录。"; return }
        do {
            let recorder = VoiceRecorder(directory: directory, segmentLength: Self.segmentLength)
            recorder.onSegment = { [weak self] url, start, duration in
                Task { @MainActor in self?.sealed(url: url, start: start, duration: duration) }
            }
            recorder.onError = { [weak self] message in
                Task { @MainActor in self?.errorMessage = "录音中断：" + message; self?.end(status: "已中断") }
            }
            try recorder.start()
            self.recorder = recorder; enabled = true; status = "正在录音"
            installObservers(); process()
        } catch { errorMessage = "无法开始录音：" + error.localizedDescription }
    }

    private func end(status: String) {
        recorder?.stop(); recorder = nil; enabled = false; self.status = status
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    /// Sleep and audio-device changes end the current segment; recording resumes afterwards.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recorder?.stop(); self?.status = "Mac 睡眠中，已暂停" }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            },
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recorder?.stop(); self?.resume() }
            },
        ]
    }
    private func resume() {
        guard enabled, let recorder else { return }
        do { try recorder.start(); status = "正在录音" }
        catch { errorMessage = "无法继续录音：" + error.localizedDescription; end(status: "已中断") }
    }

    private func sealed(url: URL, start: Date, duration: TimeInterval) {
        segments.append(VoiceSegment(start: start, duration: duration, fileName: url.lastPathComponent))
        save(); process()
    }

    /// Transcribes waiting segments one at a time, oldest first.
    private func process() {
        guard worker == nil, #available(macOS 26.0, *) else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.segments.first(where: { $0.state == .waiting }) {
                let url = self.directory.appendingPathComponent(next.fileName)
                var updated = next
                do {
                    let text = try await VoiceTranscription.text(of: url)
                    updated.text = text; updated.state = text.isEmpty ? .silent : .done
                    // Nothing was said: the audio has no further use.
                    if text.isEmpty { try? FileManager.default.removeItem(at: url); updated.audioDeleted = true }
                } catch {
                    updated.state = .failed; updated.error = error.localizedDescription
                    self.errorMessage = "转写失败：" + error.localizedDescription
                }
                if let index = self.segments.firstIndex(where: { $0.id == next.id }) { self.segments[index] = updated }
                self.prune(); self.save()
            }
            self?.worker = nil
        }
    }

    func retryFailed() {
        for index in segments.indices where segments[index].state == .failed && !segments[index].audioDeleted {
            segments[index].state = .waiting; segments[index].error = nil
        }
        errorMessage = nil; save(); process()
    }

    /// Old audio goes first; its text is kept. Audio still waiting for transcription is never removed.
    private func prune() {
        measure()
        let cutoff = Date().addingTimeInterval(-Self.audioRetention)
        for index in segments.indices where !segments[index].audioDeleted && segments[index].state != .waiting {
            guard segments[index].start < cutoff || audioBytes > Self.audioLimitBytes else { continue }
            let url = directory.appendingPathComponent(segments[index].fileName)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? FileManager.default.removeItem(at: url)
            segments[index].audioDeleted = true; audioBytes -= size
        }
    }
    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        audioBytes = files.filter { $0.pathExtension == "m4a" }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func deleteEverything() {
        end(status: "已关闭"); worker?.cancel(); worker = nil
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        segments = []; audioBytes = 0; errorMessage = nil
    }
}

/// Settings for the experiment. Looking at this panel never starts recording.
@MainActor struct LifeVoiceExperimentPanel: View {
    @ObservedObject private var voice = LifeVoiceExperiment.shared
    @State private var confirmingDelete = false
    private var recent: [VoiceSegment] { voice.segments.filter { $0.state == .done }.suffix(40).reversed() }
    private func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d月%d日 %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("试验功能：把身边的声音转成文字", isOn: Binding(get: { voice.enabled }, set: { voice.setEnabled($0) }))
            Text("开启后用这台 Mac 的麦克风录音，每 2 分钟一段，在本机转成文字。录音和文字只保存在这台 Mac 上，不上传、不同步。会录到周围其他人的声音，请在合适的场合使用。每次打开人生记录都需要重新开启。")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("状态", value: voice.status)
            if voice.waitingCount > 0 { LabeledContent("等待转写", value: "\(voice.waitingCount) 段") }
            LabeledContent("录音占用", value: ByteCountFormatter.string(fromByteCount: voice.audioBytes, countStyle: .file) + "（上限 1 GB，录音最多保留 3 天）")
            if let error = voice.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                if voice.segments.contains(where: { $0.state == .failed && !$0.audioDeleted }) { Button("重新转写失败的片段") { voice.retryFailed() } }
            }
            DisclosureGroup("最近转出的文字 · \(recent.count) 段") {
                if recent.isEmpty { Text("还没有内容。没有人说话的片段不会出现在这里。").font(.callout).foregroundStyle(.secondary) }
                ForEach(recent) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clock(segment.start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 3)
                }
            }
            HStack {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([voice.directory]) }
                Button("删除全部录音和文字…", role: .destructive) { confirmingDelete = true }.disabled(voice.segments.isEmpty && voice.audioBytes == 0)
            }
        }
        .confirmationDialog("删除全部录音和转出的文字？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { voice.deleteEverything() }
        } message: { Text("会停止录音并清空这个试验功能保存的所有内容，无法恢复。时间和账目记录不受影响。") }
    }
}
