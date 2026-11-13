import Foundation
import Observation
import Network
import CryptoKit
import LifeStore

private final class NearbyObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

@MainActor @Observable
public final class NearbySyncController {
    public var enabled: Bool = false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "life.nearby.enabled")
            if enabled { start() } else { suspend(); state = "已关闭" }
        }
    }
    public private(set) var state = "已关闭"
    public private(set) var lastSuccess: Date?
    public private(set) var errorMessage: String?
    public private(set) var peers: [NearbyPeer] = []
    public private(set) var pairingCode: String?
    public private(set) var pairingExpiresAt: Date?
    public private(set) var pairingRequest: NearbyPairingRequest?
    @ObservationIgnored private let store: LifeStore
    @ObservationIgnored private var saveVault: (NearbyVault) throws -> Void = NearbyKeychain.save
    @ObservationIgnored private var savesPreferences = true
    @ObservationIgnored private var vault: NearbyVault?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerGeneration = UUID()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browserGeneration = UUID()
    @ObservationIgnored private var networkRetryAfter = Date.distantPast
    @ObservationIgnored private var channels: [UUID: NearbyChannel] = [:]
    @ObservationIgnored private var discovered: [String: NWEndpoint] = [:]
    @ObservationIgnored private var connectingServices: [String: UUID] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var failureCounts: [String: Int] = [:]
    @ObservationIgnored private var activeToken: PairingToken?
    @ObservationIgnored private var hostingPair = false
    @ObservationIgnored private var pairingChannelID: UUID?
    @ObservationIgnored private var suspended = true
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var observedGeneration: UInt64 = 0
    @ObservationIgnored private let observer = NearbyObserver()
    private static let serviceType = "_liferecord._tcp"

    public init(store: LifeStore) {
        self.store = store
        do { vault = try NearbyKeychain.read() } catch { errorMessage = error.localizedDescription }
        observedGeneration = store.changeGeneration
        lastSuccess = UserDefaults.standard.object(forKey: "life.nearby.lastSuccess") as? Date
        refreshPeers()
        enabled = UserDefaults.standard.bool(forKey: "life.nearby.enabled")
        state = enabled ? "打开应用后开始连接" : "已关闭"
        observeStore()
    }
    // Dependency injection keeps protocol tests isolated from the person's real Keychain and settings.
    init(store: LifeStore, identity: NearbyVault, saveIdentity: @escaping (NearbyVault) throws -> Void = { _ in }) {
        self.store = store; vault = identity; saveVault = saveIdentity; savesPreferences = false
        observedGeneration = store.changeGeneration; refreshPeers(); observeStore()
    }
    private func observeStore() {
        observer.token = NotificationCenter.default.addObserver(forName: LifeStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.storeChanged() }
        }
    }

    public func start() {
        guard enabled, vault != nil else { return }
        guard suspended else {
            if browser == nil { startBrowser() }
            if listener == nil { restartListener() }
            return
        }
        suspended = false; errorMessage = nil; state = "正在找已配对的设备…"
        restartListener(); startBrowser()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if let token = self.activeToken, token.expiresAt <= Date() {
                    self.cancelPairing(); self.errorMessage = NearbyError.expiredToken.localizedDescription
                }
                for channel in Array(self.channels.values) where channel.syncDeadline.map({ $0 <= Date() }) == true {
                    channel.stop(NearbyError.protocolFailure("同步确认超时，附近时会自动重试。"))
                }
                if self.networkRetryAfter <= Date() {
                    if self.browser == nil { self.startBrowser() }
                    if self.listener == nil { self.restartListener() }
                }
                self.storeChanged(); self.connectDiscovered()
            }
        }
    }
    public func suspend() {
        suspended = true; maintenance?.cancel(); maintenance = nil
        browserGeneration = UUID(); browser?.cancel(); browser = nil
        listenerGeneration = UUID(); listener?.cancel(); listener = nil
        // Temporary credentials are invalid as soon as the app leaves the foreground.
        activeToken = nil; hostingPair = false; pairingCode = nil; pairingExpiresAt = nil; pairingRequest = nil; pairingChannelID = nil
        let active = Array(channels.values); channels.removeAll(); connectingServices.removeAll(); discovered.removeAll()
        active.forEach { $0.stop() }; refreshPeers()
        state = enabled ? "回到应用后继续" : "已关闭"
    }
    public func createPairingCode() {
        guard vault != nil else { return }
        if !enabled { enabled = true }; start(); cancelPairing()
        do {
            let token = try PairingToken.create(serviceID: UUID().uuidString)
            activeToken = token; hostingPair = true; pairingCode = try token.encoded(); pairingExpiresAt = token.expiresAt
            errorMessage = nil; state = "等 iPhone 扫码"; restartListener()
        } catch { fail(error) }
    }
    public func acceptPairingCode(_ code: String) {
        guard vault != nil else { return }
        do {
            let token = try PairingToken.parse(code)
            if !enabled { enabled = true }; start(); cancelPairing()
            activeToken = token; hostingPair = false; pairingExpiresAt = token.expiresAt
            errorMessage = nil; state = "正在连接配对设备…"; restartListener(); connectDiscovered()
        } catch { fail(error) }
    }
    public func confirmPairing() {
        guard let id = pairingChannelID, let channel = channels[id], let token = activeToken, token.expiresAt > Date(), channel.hello != nil else { return }
        channel.localConfirmed = true; channel.send(.confirm); updatePairingRequest(channel)
        finishPairingIfConfirmed(channel)
    }
    public func cancelPairing() {
        let pairID = activeToken?.pairID
        activeToken = nil; hostingPair = false; pairingCode = nil; pairingExpiresAt = nil; pairingRequest = nil; pairingChannelID = nil
        for channel in Array(channels.values) where channel.hello?.pairID == pairID && !channel.authenticated {
            channel.send(.cancel); channel.stop()
        }
        if !suspended { restartListener() }
    }
    public func removePeer(_ id: UUID) {
        guard var updated = vault else { return }
        updated.credentials.removeAll { $0.peerID == id }
        do {
            try saveVault(updated); vault = updated
            for channel in Array(channels.values) where channel.hello?.deviceID == id { channel.stop() }
            // Cancelled listener + disabled TLS tickets means removed keys cannot resume a session.
            restartListener(); refreshPeers(); errorMessage = nil
            state = "已解除配对"
        } catch { fail(error) }
    }
    public func syncNow() {
        guard enabled else { return }; start(); errorMessage = nil
        for channel in channels.values where channel.authenticated {
            channel.receipts.invalidate(); sendInventory(channel)
            do { try sendChanges(channel) } catch { channel.stop(error) }
        }
        connectDiscovered()
        if !channels.values.contains(where: { $0.authenticated }) { state = "正在找已配对的设备…" }
    }

    private var displayName: String {
        #if os(macOS)
        String((Host.current().localizedName ?? "Mac").prefix(80))
        #else
        "iPhone"
        #endif
    }
    private func restartListener() {
        listenerGeneration = UUID(); listener?.cancel(); listener = nil
        guard !suspended, let vault else { return }
        var keys = vault.credentials.map { ($0.pairID, $0.key) }
        if let token = activeToken, token.expiresAt > Date(), !keys.contains(where: { $0.0 == token.pairID }) { keys.append((token.pairID, token.key)) }
        guard !keys.isEmpty else { return }
        do {
            let listener = try NWListener(using: NearbyTLS.parameters(keys: keys))
            let serviceID = hostingPair ? (activeToken?.serviceID ?? vault.serviceID) : vault.serviceID
            listener.service = NWListener.Service(name: serviceID, type: Self.serviceType, txtRecord: NWTXTRecord(["v": "1"]))
            let generation = listenerGeneration
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerGeneration == generation, !self.suspended, self.channels.count < 8 else { connection.cancel(); return }
                    self.attach(connection, outgoing: false)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerGeneration == generation else { return }
                    if case .failed(let error) = state {
                        self.listener?.cancel(); self.listener = nil
                        self.networkRetryAfter = Date().addingTimeInterval(10); self.fail(error)
                    }
                }
            }
            self.listener = listener; listener.start(queue: .main)
        } catch { fail(error) }
    }
    private func startBrowser() {
        guard browser == nil else { return }
        let parameters = NWParameters(); parameters.includePeerToPeer = true
        browserGeneration = UUID(); let generation = browserGeneration
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.suspended, self.browserGeneration == generation else { return }
                var found: [String: NWEndpoint] = [:]
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint { found[name] = result.endpoint }
                }
                self.discovered = found; self.connectDiscovered()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.browserGeneration == generation else { return }
                if case .failed(let error) = state {
                    self.browser?.cancel(); self.browser = nil
                    self.networkRetryAfter = Date().addingTimeInterval(10); self.fail(error)
                }
            }
        }
        self.browser = browser; browser.start(queue: .main)
    }
    private func connectDiscovered() {
        guard !suspended, let vault else { return }
        var candidates: [(String, UUID, Data)] = vault.credentials.filter(\.isFinalized).map { ($0.remoteServiceID, $0.pairID, $0.key) }
        if let token = activeToken, !hostingPair, token.expiresAt > Date() { candidates.insert((token.serviceID, token.pairID, token.key), at: 0) }
        for (service, pairID, key) in candidates {
            guard service != vault.serviceID, let endpoint = discovered[service], connectingServices[service] == nil,
                  (retryAfter[service] ?? .distantPast) <= Date(), !channels.values.contains(where: { $0.hello?.pairID == pairID || $0.expectedPairID == pairID }) else { continue }
            let connection = NWConnection(to: endpoint, using: NearbyTLS.parameters(keys: [(pairID, key)], clientIdentity: pairID))
            let channel = attach(connection, outgoing: true, expectedPairID: pairID)
            connectingServices[service] = channel.id
        }
    }
    @discardableResult func attach(_ connection: NWConnection, outgoing: Bool, expectedPairID: UUID? = nil) -> NearbyChannel {
        let channel = NearbyChannel(connection: connection, outgoing: outgoing, expectedPairID: expectedPairID)
        channels[channel.id] = channel
        channel.ready = { [weak self, weak channel] in
            guard let self, let channel, let pairID = channel.expectedPairID else { return }
            self.sendHello(channel, pairID: pairID)
        }
        channel.received = { [weak self, weak channel] message in
            guard let self, let channel else { return }; self.receive(message, channel: channel)
        }
        channel.ended = { [weak self, weak channel] error in
            guard let self, let channel else { return }
            self.channels.removeValue(forKey: channel.id)
            for service in self.connectingServices.filter({ $0.value == channel.id }).map(\.key) {
                self.connectingServices.removeValue(forKey: service)
                let count = min((self.failureCounts[service] ?? 0) + 1, 6); self.failureCounts[service] = count
                self.retryAfter[service] = Date().addingTimeInterval(min(pow(2, Double(count)), 60))
            }
            if self.pairingChannelID == channel.id { self.pairingChannelID = nil; self.pairingRequest = nil }
            self.refreshPeers()
            if !self.suspended {
                if channel.locallyPersisted && !channel.remotePersisted {
                    self.cancelPairing()
                    self.errorMessage = "配对未完成，请在双方取消配对后重新扫码。"
                    self.state = "配对没完成，请重新扫码"
                } else {
                    if let error { self.errorMessage = error.localizedDescription }
                    self.state = "已断开，靠近时自动重连"
                }
            }
        }
        channel.start(); return channel
    }
    private func key(for pairID: UUID) -> Data? {
        if let credential = vault?.credentials.first(where: { $0.pairID == pairID }) { return credential.key }
        if let token = activeToken, token.pairID == pairID, token.expiresAt > Date() { return token.key }
        return nil
    }
    private func sendHello(_ channel: NearbyChannel, pairID: UUID) {
        guard let vault, let key = key(for: pairID) else { channel.stop(NearbyError.unauthorized); return }
        channel.send(.hello(NearbyHello(pairID: pairID, key: key, deviceID: vault.deviceID, serviceID: vault.serviceID, name: displayName)))
    }
    func receive(_ message: NearbyMessage, channel: NearbyChannel) {
        do {
            if case .hello(let hello) = message { try receiveHello(hello, channel: channel); return }
            guard channel.hello != nil else { throw NearbyError.unauthorized }
            switch message {
            case .confirm:
                guard !channel.authenticated, activeToken?.pairID == channel.hello?.pairID, activeToken!.expiresAt > Date() else { throw NearbyError.unauthorized }
                channel.remoteConfirmed = true; updatePairingRequest(channel); finishPairingIfConfirmed(channel)
            case .trusted:
                guard channel.localConfirmed, channel.remoteConfirmed, channel.locallyPersisted, var updated = vault,
                      let index = updated.credentials.firstIndex(where: { $0.pairID == channel.hello?.pairID }) else { throw NearbyError.unauthorized }
                updated.credentials[index].isFinalized = true
                try saveVault(updated); vault = updated
                channel.remotePersisted = true; activate(channel)
            case .cancel: channel.stop()
            default:
                if !channel.authenticated, activeToken?.pairID == channel.hello?.pairID {
                    throw NearbyError.protocolFailure("配对未完成，请在双方取消配对后重新扫码。")
                }
                guard channel.authenticated, let credential = channel.credential,
                      vault?.credentials.contains(where: { $0.pairID == credential.pairID && $0.peerID == credential.peerID }) == true else { throw NearbyError.unauthorized }
                try receiveSync(message, channel: channel)
            }
        } catch { channel.stop(error) }
    }
    private func receiveHello(_ hello: NearbyHello, channel: NearbyChannel) throws {
        guard channel.hello == nil, let vault, hello.version == 1 else { throw NearbyError.incompatible }
        guard hello.deviceID != vault.deviceID, channel.expectedPairID == nil || channel.expectedPairID == hello.pairID,
              let key = key(for: hello.pairID), hello.verify(key: key) else { throw NearbyError.unauthorized }
        let known = vault.credentials.first { $0.pairID == hello.pairID }
        if let known, known.peerID != hello.deviceID { throw NearbyError.unauthorized }
        // The same pair may be discovered from both ends. Keep the direction chosen by UUID order.
        if let other = channels.values.first(where: { $0.id != channel.id && $0.hello?.deviceID == hello.deviceID }) {
            let preferOutgoing = vault.deviceID.uuidString < hello.deviceID.uuidString
            if channel.outgoing == preferOutgoing && other.outgoing != preferOutgoing { other.stop() }
            else { channel.stop(); return }
        }
        channel.hello = hello
        if !channel.outgoing { sendHello(channel, pairID: hello.pairID) }
        if var known {
            guard known.isFinalized else {
                throw NearbyError.protocolFailure("配对未完成，请在双方取消配对后重新扫码。")
            }
            known.peerName = hello.name; known.remoteServiceID = hello.serviceID
            channel.credential = known; channel.markAuthenticated(); activate(channel)
        } else {
            guard activeToken?.pairID == hello.pairID, activeToken!.expiresAt > Date(), pairingChannelID == nil || pairingChannelID == channel.id else { throw NearbyError.unauthorized }
            pairingChannelID = channel.id; channel.allowPairing(until: activeToken!.expiresAt); updatePairingRequest(channel); state = "请在两台设备上确认"
        }
    }
    private func updatePairingRequest(_ channel: NearbyChannel) {
        guard let hello = channel.hello else { return }
        pairingRequest = NearbyPairingRequest(id: hello.deviceID, displayName: hello.name, localConfirmed: channel.localConfirmed, remoteConfirmed: channel.remoteConfirmed)
    }
    private func finishPairingIfConfirmed(_ channel: NearbyChannel) {
        guard channel.localConfirmed, channel.remoteConfirmed, !channel.locallyPersisted,
              let hello = channel.hello, let token = activeToken, token.pairID == hello.pairID, token.expiresAt > Date(), var updated = vault else { return }
        do {
            let credential = PeerCredential(pairID: token.pairID, key: token.key, peerID: hello.deviceID, peerName: hello.name, remoteServiceID: hello.serviceID, isFinalized: false)
            updated.credentials.removeAll { $0.peerID == credential.peerID }; updated.credentials.append(credential)
            try saveVault(updated); vault = updated; channel.credential = credential; channel.locallyPersisted = true
            channel.send(.trusted); refreshPeers()
            if channel.remotePersisted { activate(channel) }
        } catch { channel.stop(error); fail(error) }
    }
    private func activate(_ channel: NearbyChannel) {
        guard channel.credential != nil else { return }
        if !channel.authenticated {
            guard channel.localConfirmed, channel.remoteConfirmed, channel.locallyPersisted, channel.remotePersisted else { return }
            channel.markAuthenticated()
        }
        if channel.hello?.pairID == activeToken?.pairID {
            activeToken = nil; hostingPair = false; pairingCode = nil; pairingExpiresAt = nil; pairingRequest = nil; pairingChannelID = nil
            restartListener()
        }
        errorMessage = nil; state = "已连接，正在核对记录…"; refreshPeers(); sendInventory(channel)
    }
    private func storeChanged() {
        guard observedGeneration != store.changeGeneration else { return }; observedGeneration = store.changeGeneration
        for channel in channels.values where channel.authenticated {
            channel.receipts.invalidate(); sendInventory(channel)
            do { try sendChanges(channel) } catch { channel.stop(error) }
        }
    }
    private func sendInventory(_ channel: NearbyChannel) {
        do {
            if channel.syncDeadline == nil { channel.syncDeadline = Date().addingTimeInterval(45) }
            channel.send(.inventory(try store.inventory()))
        } catch { channel.stop(error) }
    }
    private func digest(_ inventory: SyncInventory) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(inventory)).map { String(format: "%02x", $0) }.joined()
    }
    private func receiveSync(_ message: NearbyMessage, channel: NearbyChannel) throws {
        channel.syncDeadline = Date().addingTimeInterval(45)
        switch message {
        case .inventory(let inventory):
            guard inventory.protocolVersion == 1 else { throw NearbyError.incompatible }
            channel.remoteInventory = inventory; try sendChanges(channel)
        case .batch(let id, let batch):
            guard batch.protocolVersion == 1 else { throw NearbyError.incompatible }
            // Always validate duplicates as well: the same transaction ID must not hide altered bytes.
            let result = try store.importBatch(batch)
            if result.hasChanges { channel.receipts.invalidate() }
            // importBatch commits atomically before this durable acknowledgement is sent.
            channel.send(.ack(id, try store.inventory()))
            sendInventory(channel)
        case .ack(let id, let inventory):
            guard inventory.protocolVersion == 1, channel.receipts.acknowledge(id) else { throw NearbyError.invalidFrame }
            channel.remoteInventory = inventory; try sendChanges(channel)
        case .seal(let remoteDigest):
            let current = try store.inventory(); let currentDigest = try digest(current)
            if remoteDigest == currentDigest {
                channel.receipts.receivedSeal = remoteDigest; channel.send(.sealAck(remoteDigest)); try sendChanges(channel); checkSuccess(channel, digest: currentDigest)
            } else { channel.receipts.invalidate(); sendInventory(channel) }
        case .sealAck(let remoteDigest):
            guard channel.receipts.sentSeal == remoteDigest else { return }
            let currentDigest = try digest(store.inventory())
            if currentDigest == remoteDigest { channel.receipts.acknowledgedSeal = remoteDigest; checkSuccess(channel, digest: currentDigest) }
            else { channel.receipts.invalidate(); sendInventory(channel) }
        default: throw NearbyError.invalidFrame
        }
    }
    private func sendChanges(_ channel: NearbyChannel) throws {
        guard channel.receipts.pendingBatch == nil, let remote = channel.remoteInventory else { return }
        let local = try store.inventory()
        if local == remote {
            let fingerprint = try digest(local)
            if channel.receipts.sentSeal != fingerprint { channel.receipts.sentSeal = fingerprint; channel.send(.seal(fingerprint)) }
            checkSuccess(channel, digest: fingerprint)
        } else {
            let batch = try store.exportBatch(excluding: remote, limit: 256, maxBytes: 4 * 1024 * 1024)
            if !batch.recordRevisions.isEmpty || !batch.timerRevisions.isEmpty {
                let id = UUID(); channel.receipts.invalidate(); channel.receipts.pendingBatch = id
                channel.send(.batch(id, batch)); state = "正在同步…"
            }
            // If only the remote has missing revisions, its independent sender supplies them.
        }
    }
    private func checkSuccess(_ channel: NearbyChannel, digest: String) {
        guard channel.receipts.complete(digest: digest) else { return }
        lastSuccess = Date()
        if savesPreferences { UserDefaults.standard.set(lastSuccess, forKey: "life.nearby.lastSuccess") }
        channel.syncDeadline = nil; errorMessage = nil
        state = store.conflicts.isEmpty ? "已同步" : "已同步 · 有记录需要你核对"
        refreshPeers()
    }
    private func refreshPeers() {
        peers = (vault?.credentials ?? []).map { credential in
            let connected = channels.values.contains { $0.authenticated && $0.hello?.deviceID == credential.peerID }
            let previous = peers.first { $0.id == credential.peerID }
            return NearbyPeer(id: credential.peerID, displayName: credential.peerName, lastSeen: connected ? Date() : previous?.lastSeen, isConnected: connected)
        }.sorted { $0.displayName < $1.displayName }
    }
    private func fail(_ error: Error) { errorMessage = error.localizedDescription; state = "暂时连不上 · 本机记录照常使用" }
}
