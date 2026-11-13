import Foundation
import CryptoKit
import LifeStore

public struct NearbyPeer: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let lastSeen: Date?
    public let isConnected: Bool
}
public struct NearbyPairingRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let localConfirmed: Bool
    public let remoteConfirmed: Bool
}

enum NearbyError: LocalizedError {
    case invalidToken, expiredToken, invalidFrame, unauthorized, incompatible, keychain(Int32), protocolFailure(String)
    var errorDescription: String? {
        switch self {
        case .invalidToken: "配对码无法识别，请重新扫描或粘贴完整配对码。"
        case .expiredToken: "配对码已过期，请在电脑上重新生成。"
        case .invalidFrame: "对方发送的数据格式不正确，连接已关闭。"
        case .unauthorized: "设备尚未完成双方确认，连接已关闭。"
        case .incompatible: "两台设备的同步版本不同，请先更新应用。"
        case .keychain: "无法读取或保存本机钥匙串，同步已停止。"
        case .protocolFailure(let message): message
        }
    }
}

struct PairingToken: Codable, Sendable, Equatable {
    static let lifetime: TimeInterval = 300
    var version = 1
    let pairID: UUID
    let key: Data
    let serviceID: String
    let expiresAt: Date
    static func create(serviceID: String, now: Date = Date()) throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NearbyError.invalidToken }
        return Self(pairID: UUID(), key: Data(bytes), serviceID: serviceID, expiresAt: now.addingTimeInterval(lifetime))
    }
    func encoded() throws -> String {
        "liferecord-nearby://pair/" + (try JSONEncoder().encode(self)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func parse(_ input: String, now: Date = Date()) throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "liferecord-nearby://pair/"
        guard text.hasPrefix(prefix), text.utf8.count < 4096 else { throw NearbyError.invalidToken }
        var base = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base), let token = try? JSONDecoder().decode(Self.self, from: data), token.version == 1, token.key.count == 32, UUID(uuidString: token.serviceID) != nil else { throw NearbyError.invalidToken }
        guard token.expiresAt > now, token.expiresAt <= now.addingTimeInterval(lifetime + 5) else { throw NearbyError.expiredToken }
        return token
    }
}

struct PeerCredential: Codable, Sendable {
    let pairID: UUID
    let key: Data
    let peerID: UUID
    var peerName: String
    var remoteServiceID: String
    var isFinalized: Bool = true
}
struct NearbyVault: Codable, Sendable {
    var deviceID = UUID()
    var serviceID = UUID().uuidString
    var credentials: [PeerCredential] = []
}
struct NearbyHello: Codable, Sendable {
    let version: Int
    let pairID: UUID
    let deviceID: UUID
    let serviceID: String
    let name: String
    let nonce: UUID
    let proof: Data
    private var signedBytes: Data { Self.bytes(version: version, pairID: pairID, deviceID: deviceID, serviceID: serviceID, name: name, nonce: nonce) }
    private static func bytes(version: Int, pairID: UUID, deviceID: UUID, serviceID: String, name: String, nonce: UUID) -> Data {
        // JSON gives an unambiguous encoding even if a display name contains separators.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode([String(version), pairID.uuidString, deviceID.uuidString, serviceID, name, nonce.uuidString])) ?? Data()
    }
    init(pairID: UUID, key: Data, deviceID: UUID, serviceID: String, name: String) {
        version = 1; self.pairID = pairID; self.deviceID = deviceID; self.serviceID = serviceID
        self.name = String(name.prefix(80)); nonce = UUID()
        proof = Data(HMAC<SHA256>.authenticationCode(for: Self.bytes(version: 1, pairID: pairID, deviceID: deviceID, serviceID: serviceID, name: self.name, nonce: nonce), using: SymmetricKey(data: key)))
    }
    func verify(key: Data) -> Bool {
        version == 1 && name.utf8.count <= 320 && UUID(uuidString: serviceID) != nil && HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: signedBytes, using: SymmetricKey(data: key))
    }
}

enum NearbyMessage: Codable, Sendable {
    case hello(NearbyHello)
    case confirm
    case trusted
    case inventory(SyncInventory)
    case batch(UUID, SyncBatch)
    case ack(UUID, SyncInventory)
    case seal(String)
    case sealAck(String)
    case cancel
}
struct FrameDecoder {
    static let maximumBytes = 8 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= Self.maximumBytes else { throw NearbyError.invalidFrame }
            guard buffer.count >= Int(length) + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(Int(length))))
            buffer.removeFirst(Int(length) + 4)
        }
        guard buffer.count <= Self.maximumBytes + 4 else { throw NearbyError.invalidFrame }
        return frames
    }
    static func encode(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes else { throw NearbyError.invalidFrame }
        let size = UInt32(data.count)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + data
    }
}

/// A completed round requires matching inventories and an acknowledgement in both directions.
struct SyncReceiptState {
    var sentSeal: String?
    var acknowledgedSeal: String?
    var receivedSeal: String?
    var pendingBatch: UUID?
    var acknowledgedBatches = Set<UUID>()
    mutating func invalidate() { sentSeal = nil; acknowledgedSeal = nil; receivedSeal = nil }
    mutating func acknowledge(_ id: UUID) -> Bool {
        guard pendingBatch == id else { return acknowledgedBatches.contains(id) }
        pendingBatch = nil; acknowledgedBatches.insert(id); invalidate(); return true
    }
    func complete(digest: String) -> Bool {
        pendingBatch == nil && sentSeal == digest && acknowledgedSeal == digest && receivedSeal == digest
    }
}
import Security
