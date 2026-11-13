import Foundation
import Network
import Security

/// All connections use authenticated TLS 1.2 PSK. No certificate-verification bypass exists.
enum NearbyTLS {
    static let queue = DispatchQueue(label: "local.liferecord.nearby.psk")
    static func parameters(keys: [(UUID, Data)], clientIdentity: UUID? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        for (id, key) in keys {
            sec_protocol_options_add_pre_shared_key(options, dispatchData(key), dispatchData(Data(id.uuidString.utf8)))
        }
        if let clientIdentity {
            let identity = Data(clientIdentity.uuidString.utf8)
            sec_protocol_options_set_pre_shared_key_selection_block(options, { _, _, complete in
                complete(dispatchData(identity))
            }, queue)
        }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
    static func dispatchData(_ data: Data) -> dispatch_data_t { data.withUnsafeBytes { DispatchData(bytes: $0) } as dispatch_data_t }
    static func authenticated(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv12 && sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)
    }
}

@MainActor final class NearbyChannel {
    let id = UUID()
    let connection: NWConnection
    let outgoing: Bool
    let expectedPairID: UUID?
    var ready: (() -> Void)?
    var received: ((NearbyMessage) -> Void)?
    var ended: ((Error?) -> Void)?
    var hello: NearbyHello?
    var credential: PeerCredential?
    var localConfirmed = false
    var remoteConfirmed = false
    var locallyPersisted = false
    var remotePersisted = false
    var authenticated = false
    var receipts = SyncReceiptState()
    var remoteInventory: SyncInventory?
    var syncDeadline: Date?
    private var decoder = FrameDecoder()
    private var stopped = false
    private var timeout: Task<Void, Never>?
    init(connection: NWConnection, outgoing: Bool, expectedPairID: UUID? = nil) {
        self.connection = connection; self.outgoing = outgoing; self.expectedPairID = expectedPairID
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    guard NearbyTLS.authenticated(self.connection) else { self.stop(NearbyError.unauthorized); return }
                    self.ready?(); self.receive()
                case .failed(let error): self.stop(error)
                case .cancelled: self.stop(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, let self, !self.authenticated else { return }
            self.stop(NearbyError.protocolFailure("设备确认超时，请重新连接。"))
        }
    }
    func markAuthenticated() { authenticated = true; timeout?.cancel(); timeout = nil; syncDeadline = Date().addingTimeInterval(45) }
    func allowPairing(until expiry: Date) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, !self.authenticated else { return }
            self.stop(NearbyError.expiredToken)
        }
    }
    func send(_ message: NearbyMessage) {
        guard !stopped else { return }
        do {
            let data = try FrameDecoder.encode(JSONEncoder().encode(message))
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { Task { @MainActor [weak self] in self?.stop(error) } }
            })
        } catch { stop(error) }
    }
    func stop(_ error: Error? = nil) {
        guard !stopped else { return }; stopped = true
        timeout?.cancel(); timeout = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let callback = ended; ready = nil; received = nil; ended = nil
        callback?(error)
    }
    private func receive() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                do {
                    if let data {
                        for frame in try self.decoder.append(data) {
                            let message = try JSONDecoder().decode(NearbyMessage.self, from: frame)
                            self.received?(message)
                            if self.stopped { return }
                        }
                    }
                    if let error { self.stop(error) }
                    else if complete { self.stop(nil) }
                    else { self.receive() }
                } catch { self.stop(NearbyError.invalidFrame) }
            }
        }
    }
}
import LifeStore
