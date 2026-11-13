import Testing
import Foundation
import Network
import LifeStore
@testable import LifeNearby

struct NearbyProtocolTests {
    @Test func framesHandlePartialAndMultipleMessages() throws {
        let first = Data("第一条".utf8), second = Data("second".utf8)
        let framed = try FrameDecoder.encode(first) + FrameDecoder.encode(second)
        var decoder = FrameDecoder()
        let partial = try decoder.append(framed.prefix(2)); #expect(partial.isEmpty)
        let decoded = try decoder.append(framed.dropFirst(2)); #expect(decoded == [first, second])
    }
    @Test func oversizedAndZeroFramesAreRejected() {
        var decoder = FrameDecoder()
        #expect(throws: (any Error).self) { try decoder.append(Data([0, 128, 0, 1])) }
        var zero = FrameDecoder()
        #expect(throws: (any Error).self) { try zero.append(Data([0, 0, 0, 0])) }
    }
    @Test func tokenRequiresValidVersionSecretAndFiveMinuteExpiry() throws {
        let now = Date()
        let token = try PairingToken.create(serviceID: UUID().uuidString, now: now)
        #expect(try PairingToken.parse(token.encoded(), now: now) == token)
        #expect(throws: (any Error).self) { try PairingToken.parse(token.encoded(), now: now.addingTimeInterval(301)) }
        #expect(throws: (any Error).self) { try PairingToken.parse("not-a-pairing-code") }
        var newer = token; newer.version = 2
        #expect(throws: (any Error).self) { try PairingToken.parse(newer.encoded(), now: now) }
        #expect(token.key.count == 32)
    }
    @Test func helloIsBoundToThePairSecretAndIdentity() throws {
        let token = try PairingToken.create(serviceID: UUID().uuidString)
        let hello = NearbyHello(pairID: token.pairID, key: token.key, deviceID: UUID(), serviceID: UUID().uuidString, name: "My Mac")
        #expect(hello.verify(key: token.key))
        #expect(!hello.verify(key: Data(repeating: 3, count: 32)))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
        json["deviceID"] = UUID().uuidString
        let altered = try JSONDecoder().decode(NearbyHello.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!altered.verify(key: token.key))
    }
    @Test func successNeedsBothPersistentReceiptsAndNoPendingBatch() {
        var state = SyncReceiptState(); let batch = UUID()
        state.sentSeal = "same"; state.receivedSeal = "same"
        #expect(!state.complete(digest: "same"))
        state.acknowledgedSeal = "same"
        #expect(state.complete(digest: "same"))
        state.pendingBatch = batch
        #expect(!state.complete(digest: "same"))
        let unknown = state.acknowledge(UUID()); #expect(!unknown)
        let acknowledged = state.acknowledge(batch); #expect(acknowledged)
        #expect(!state.complete(digest: "same"))
        let duplicate = state.acknowledge(batch); #expect(duplicate) // duplicate receipt is harmless
    }
    @Test @MainActor func newConnectionCannotSynchronizeWithoutConfirmation() {
        let channel = NearbyChannel(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), outgoing: true)
        #expect(!channel.authenticated)
        #expect(!channel.localConfirmed && !channel.remoteConfirmed)
        #expect(!channel.locallyPersisted && !channel.remotePersisted)
    }
}

@MainActor private final class TLSLoopback {
    let listener: NWListener
    var port: NWEndpoint.Port?
    var incoming: [NWConnection] = []
    var client: NWConnection?
    var clientReady = false
    var clientFailed = false
    var serverReady = false
    init(keys: [(UUID, Data)]) throws {
        listener = try NWListener(using: NearbyTLS.parameters(keys: keys))
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .ready = state { self.port = self.listener.port }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.incoming.append(connection)
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        if case .ready = state { self?.serverReady = NearbyTLS.authenticated(connection) }
                    }
                }
                connection.start(queue: .main)
            }
        }
        listener.start(queue: .main)
    }
    func connect(id: UUID, key: Data) async throws {
        for _ in 0..<300 where port == nil { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(port)
        clientReady = false; clientFailed = false; serverReady = false
        let connection = NWConnection(host: "127.0.0.1", port: port, using: NearbyTLS.parameters(keys: [(id, key)], clientIdentity: id))
        client = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .ready = state { self?.clientReady = NearbyTLS.authenticated(connection) }
                if case .failed = state { self?.clientFailed = true }
            }
        }
        connection.start(queue: .main)
        for _ in 0..<500 where !clientReady && !clientFailed { try await Task.sleep(for: .milliseconds(10)) }
    }
    func stopClient() { client?.cancel(); client = nil; incoming.forEach { $0.cancel() }; incoming.removeAll() }
    func stop() { stopClient(); listener.cancel() }
}

struct NearbyTLSRealConnectionTests {
    @Test @MainActor func actualTLSAcceptsNonFirstOfMultiplePSKsAndRejectsWrongKey() async throws {
        let keys = (0..<3).map { index in (UUID(), Data(repeating: UInt8(index + 10), count: 32)) }
        let network = try TLSLoopback(keys: keys)
        defer { network.stop() }
        for (id, key) in keys.reversed() {
            try await network.connect(id: id, key: key)
            #expect(network.clientReady)
            for _ in 0..<100 where !network.serverReady { try await Task.sleep(for: .milliseconds(10)) }
            #expect(network.serverReady)
            network.stopClient()
        }
        try await network.connect(id: keys[1].0, key: Data(repeating: 99, count: 32))
        #expect(!network.clientReady)
    }
    @Test @MainActor func removedPSKCannotReconnectToReplacementListener() async throws {
        let old = (UUID(), Data(repeating: UInt8(77), count: 32))
        let replacement = (UUID(), Data(repeating: UInt8(88), count: 32))
        let network = try TLSLoopback(keys: [replacement])
        defer { network.stop() }
        try await network.connect(id: old.0, key: old.1)
        #expect(!network.clientReady)
    }
}

@MainActor private final class ControllerLink {
    let listener: NWListener
    var port: NWEndpoint.Port?
    var client: NearbyChannel?
    var server: NearbyChannel?
    let left: NearbySyncController
    let right: NearbySyncController
    let pairID: UUID
    let key: Data
    init(left: NearbySyncController, right: NearbySyncController, pairID: UUID, key: Data) throws {
        self.left = left; self.right = right; self.pairID = pairID; self.key = key
        listener = try NWListener(using: NearbyTLS.parameters(keys: [(pairID, key)]))
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in if case .ready = state { self?.port = self?.listener.port } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.server = self.right.attach(connection, outgoing: false)
            }
        }
        listener.start(queue: .main)
    }
    func connect() async throws {
        for _ in 0..<300 where port == nil { try await Task.sleep(for: .milliseconds(10)) }
        let connection = NWConnection(host: "127.0.0.1", port: try #require(port), using: NearbyTLS.parameters(keys: [(pairID, key)], clientIdentity: pairID))
        client = left.attach(connection, outgoing: true, expectedPairID: pairID)
    }
    func stop() { client?.stop(); server?.stop(); listener.cancel() }
}

struct NearbyControllerTests {
    @Test @MainActor func unpairedAndOneSidedConfirmationCannotImportRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try LifeStore(databaseURL: directory.appendingPathComponent("source.sqlite"))
        let destination = try LifeStore(databaseURL: directory.appendingPathComponent("destination.sqlite"))
        try source.save(.init(amountCents: 100, kind: .expense, category: "测试", merchant: "测试商户"))
        let batch = try source.exportBatch(excluding: destination.inventory())
        let controller = NearbySyncController(store: destination, identity: NearbyVault())
        let token = try PairingToken.create(serviceID: UUID().uuidString)
        for localConfirmed in [false, true] {
            let channel = NearbyChannel(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), outgoing: false)
            channel.hello = NearbyHello(pairID: token.pairID, key: token.key, deviceID: UUID(), serviceID: UUID().uuidString, name: "Unconfirmed")
            channel.localConfirmed = localConfirmed
            var rejected = false
            channel.ended = { error in rejected = error != nil }
            controller.receive(.batch(UUID(), batch), channel: channel)
            #expect(rejected)
            #expect(try destination.inventory().recordRevisionIDs.isEmpty)
            #expect(controller.lastSuccess == nil)
        }
    }
    @Test @MainActor func incompletePersistentPairCannotBecomeTrustedOnReconnect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LifeStore(databaseURL: directory.appendingPathComponent("store.sqlite"))
        let token = try PairingToken.create(serviceID: UUID().uuidString)
        let remote = UUID()
        var vault = NearbyVault()
        vault.credentials = [.init(pairID: token.pairID, key: token.key, peerID: remote, peerName: "Other", remoteServiceID: token.serviceID, isFinalized: false)]
        let controller = NearbySyncController(store: store, identity: vault)
        let channel = NearbyChannel(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), outgoing: true, expectedPairID: token.pairID)
        var failure: String?
        channel.ended = { failure = $0?.localizedDescription }
        controller.receive(.hello(NearbyHello(pairID: token.pairID, key: token.key, deviceID: remote, serviceID: token.serviceID, name: "Other")), channel: channel)
        #expect(!channel.authenticated)
        #expect(failure?.contains("配对未完成") == true)
        #expect(controller.lastSuccess == nil)
    }
    @Test @MainActor func duplicateTransactionIDStillValidatesRevisionBytesAndOldProtocolCannotImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try LifeStore(databaseURL: directory.appendingPathComponent("source.sqlite"))
        let destination = try LifeStore(databaseURL: directory.appendingPathComponent("destination.sqlite"))
        try source.save(.init(amountCents: 100, kind: .expense, category: "测试", merchant: "原始"))
        let batch = try source.exportBatch(excluding: destination.inventory())
        let token = try PairingToken.create(serviceID: UUID().uuidString), remote = UUID()
        let credential = PeerCredential(pairID: token.pairID, key: token.key, peerID: remote, peerName: "Known", remoteServiceID: token.serviceID)
        var vault = NearbyVault(); vault.credentials = [credential]
        let controller = NearbySyncController(store: destination, identity: vault)
        func authorizedChannel() -> NearbyChannel {
            let channel = NearbyChannel(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), outgoing: true)
            channel.hello = NearbyHello(pairID: token.pairID, key: token.key, deviceID: remote, serviceID: token.serviceID, name: "Known")
            channel.credential = credential; channel.markAuthenticated(); return channel
        }
        let oldChannel = authorizedChannel()
        var old = batch; old.protocolVersion = 0
        var oldRejected = false; oldChannel.ended = { oldRejected = $0 != nil }
        controller.receive(.batch(UUID(), old), channel: oldChannel)
        #expect(oldRejected)
        #expect(try destination.inventory().recordRevisionIDs.isEmpty)
        let channel = authorizedChannel(), transactionID = UUID()
        controller.receive(.batch(transactionID, batch), channel: channel)
        #expect(destination.transactions.count == 1)
        var altered = batch; altered.recordRevisions[0].payload += " "
        var rejected = false; channel.ended = { rejected = $0 != nil }
        controller.receive(.batch(transactionID, altered), channel: channel)
        #expect(rejected)
        #expect(destination.transactions.first?.amountCents == 100)
        #expect(try destination.inventory().recordRevisionIDs.count == 1)
        #expect(controller.lastSuccess == nil)
    }
    @Test @MainActor func actualTLSControllersConvergeAcrossPagesAndSyncLaterLocalChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LifeStore(databaseURL: directory.appendingPathComponent("first.sqlite"))
        let second = try LifeStore(databaseURL: directory.appendingPathComponent("second.sqlite"))
        for index in 0..<270 { try first.save(.init(amountCents: index + 1, kind: .expense, category: "测试", merchant: "左边")) }
        try second.save(.init(amountCents: 500, kind: .expense, category: "测试", merchant: "右边"))
        let token = try PairingToken.create(serviceID: UUID().uuidString)
        var a = NearbyVault(), b = NearbyVault()
        a.credentials = [.init(pairID: token.pairID, key: token.key, peerID: b.deviceID, peerName: "B", remoteServiceID: b.serviceID)]
        b.credentials = [.init(pairID: token.pairID, key: token.key, peerID: a.deviceID, peerName: "A", remoteServiceID: a.serviceID)]
        let left = NearbySyncController(store: first, identity: a), right = NearbySyncController(store: second, identity: b)
        let link = try ControllerLink(left: left, right: right, pairID: token.pairID, key: token.key)
        defer { link.stop(); left.suspend(); right.suspend() }
        try await link.connect()
        for _ in 0..<1000 where left.lastSuccess == nil || right.lastSuccess == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(left.lastSuccess != nil && right.lastSuccess != nil)
        #expect(try first.inventory() == second.inventory())
        #expect(first.transactions.count == 271 && second.transactions.count == 271)
        let previousSuccess = left.lastSuccess
        try first.save(.init(amountCents: 900, kind: .expense, category: "测试", merchant: "同步后新增"))
        for _ in 0..<1000 where second.transactions.count != 272 || left.lastSuccess == previousSuccess { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try first.inventory() == second.inventory())
        #expect(first.transactions.count == 272 && second.transactions.count == 272)
        #expect(left.lastSuccess != previousSuccess)
        #expect(left.errorMessage == nil && right.errorMessage == nil)
    }
}
