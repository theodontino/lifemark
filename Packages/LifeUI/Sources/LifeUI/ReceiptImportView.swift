import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import Vision
import ImageIO
import CryptoKit
import LifeCore
import LifeStore

enum LifeOCR {
    static func recognize(_ data: Data) async throws -> String {
        try await Task.detached(priority:.userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw LifeAIError.message("无法打开这张图片，请换一张清晰截图。") }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans","en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage:image).perform([request])
            let text = (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
            guard !text.isEmpty else { throw LifeAIError.message("没有识别到文字。可以换图或手工填写，不会自动生成金额。") }
            return text
        }.value
    }
}
@MainActor struct ReceiptImportView: View {
    let store: LifeStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var text = ""
    @State private var fingerprint: String?
    @State private var amount = ""
    @State private var merchant = ""
    @State private var category = "餐饮"
    @State private var account = ""
    @State private var kind = TransactionKind.expense
    @State private var date = Date()
    @State private var dateWasRecognized = false
    @State private var busy = false
    @State private var error: String?
    @State private var note = ""
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            Form {
                Section("选择截图") {
                    Button { choosing = true } label: { Label("从文件选择付款截图", systemImage:"doc.viewfinder") }
                    #if os(iOS)
                    PhotosPicker(selection:$photo, matching:.images) { Label("从照片选择截图", systemImage:"photo") }
                    #endif
                    Text("文字先在本机识别。点击“AI完善草稿”时，才把识别文字发给已配置的服务。").font(.caption).foregroundStyle(.secondary)
                    if busy { ProgressView("正在处理…") }
                    if let fp = fingerprint, store.transactions.contains(where:{$0.fingerprint == fp}) {
                        Label("这张图片已经导入过，请核对是否重复记账。", systemImage:"exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    DisclosureGroup("核对识别文字") { TextEditor(text:$text).frame(minHeight:140); Button("按这些文字重新提取") { fillLocal() } }
                    Button("用 AI 完善草稿") { Task { await improve() } }.disabled(text.isEmpty || busy)
                }
                Section("核对这一笔") {
                    Picker("类型", selection:$kind) { ForEach(TransactionKind.allCases,id:\.self) { Text($0.label).tag($0) } }
                    TextField("实付金额", text:$amount).moneyInput()
                    TextField("商户", text:$merchant)
                    TextField("支付账户", text:$account)
                    Picker("分类", selection:$category) { ForEach(Array(Set(expenseCategories+[category])).sorted(),id:\.self) { Text($0).tag($0) } }
                    DatePicker("发生时间", selection:$date)
                    if !dateWasRecognized { Text("截图日期尚未识别：当前暂填今天，请特别核对。").font(.caption).foregroundStyle(.orange) }
                    TextField("备注", text:$note, axis:.vertical)
                }
                Section {
                    ErrorText(text:error)
                    Button("核对完成，入账") { save(confirmed:true) }.buttonStyle(.borderedProminent).disabled(busy)
                    Button("保存草稿，稍后核对") { save(confirmed:false) }.disabled(busy)
                }
            }.formStyle(.grouped).disabled(busy).navigationTitle("截图记账")
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
                .fileImporter(isPresented:$choosing,allowedContentTypes:[.image]) { result in
                    Task {
                        do {
                            let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let data = try Data(contentsOf:url)
                            await read(data)
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .onChange(of:photo) { _, item in
                    guard let item else { return }
                    let token = UUID(); generation = token; resetDraft(); busy = true
                    Task {
                        defer { if generation == token { busy = false } }
                        do {
                            if let data = try await item.loadTransferable(type: Data.self), generation == token { await read(data, token: token) }
                        } catch { if generation == token { self.error = error.localizedDescription } }
                    }
                }
        }.frame(idealWidth:600,idealHeight:740)
    }
    private func resetDraft() {
        text = ""; fingerprint = nil; imageData = nil; amount = ""; merchant = ""
        category = "餐饮"; account = ""; kind = .expense
        date = Date(); dateWasRecognized = false; note = ""; error = nil
    }
    private func read(_ data: Data, token supplied: UUID? = nil) async {
        let token = supplied ?? UUID()
        if supplied == nil { generation = token; resetDraft() }
        guard generation == token else { return }
        guard data.count <= 30_000_000 else { error = "图片较大，请使用30MB以内的截图。"; return }
        busy = true
        defer { if generation == token { busy = false } }
        imageData = data
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        do {
            let recognized = try await LifeOCR.recognize(data)
            guard generation == token else { return }
            text = recognized; fillLocal()
        } catch { if generation == token { self.error = error.localizedDescription } }
    }
    private func fillLocal() {
        let draft = ReceiptParser.parse(text)
        amount = draft.amountCents.map{String(format:"%.2f",Double($0)/100)} ?? ""
        kind = draft.kind; merchant = draft.merchant; note = draft.note
        if let value = draft.date { date = value; dateWasRecognized = true } else { dateWasRecognized = false }
        if text.contains("微信") { account = "微信" } else if text.contains("支付宝") { account = "支付宝" } else if text.contains("信用卡") { account = "信用卡" }
    }
    private func improve() async {
        let token = generation, sourceText = text
        busy = true; error = nil; defer { if generation == token { busy = false } }
        do {
            let response = try await LifeAI.complete(system: LifeAI.receiptSystem, content: sourceText)
            guard generation == token else { return }
            let object = try LifeAI.jsonObject(response)
            if object["needsSplit"] as? Bool == true { throw LifeAIError.message("这张图有多笔交易，请分别录入或裁剪到一笔；没有自动合并入账。") }
            guard !object.isEmpty else { throw LifeAIError.message("AI 没有识别出确定的交易，请手工核对。") }
            if let value = object["amount"] as? String, Money.parseCents(value) != nil { amount = value }
            if let value = object["merchant"] as? String { merchant = String(value.prefix(100)) }
            if let value = object["account"] as? String { account = String(value.prefix(100)) }
            if let value = object["category"] as? String { category = String(value.prefix(40)) }
            if let value = object["kind"] as? String, let parsed = TransactionKind(rawValue:value) { kind = parsed }
            if let value = object["note"] as? String { note = String(value.prefix(1000)) }
            if let value = object["date"] as? String {
                let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if let parsed = f.date(from:value) { date = parsed; dateWasRecognized = true }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save(confirmed:Bool) {
        guard let cents = Money.parseCents(amount), cents > 0 else { error = "还没有确定金额，请填写实付金额后保存。"; return }
        guard !account.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, account.trimmingCharacters(in:.whitespacesAndNewlines) != "待确认账户" else { error = "请填写支付账户。"; return }
        let item = LifeCore.Transaction(amountCents:cents,kind:kind,category:category,merchant:merchant,date:date,note:note,source:.screenshot,status:confirmed ? .confirmed : .pending,fingerprint:fingerprint,account:account)
        do { try store.save(item, ifUnchangedFrom: nil); dismiss() } catch { self.error = error.localizedDescription }
    }
}
