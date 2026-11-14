#if os(iOS)
import Foundation
import Security
import StrandGlucose

/// The wearer's Dexcom account, stored only in this device's Keychain (never in backups that leave the
/// device, never in UserDefaults).
struct DexcomShareCredentials: Codable, Equatable {
    var username: String
    var password: String
    var region: DexcomShareRegion
}

enum DexcomShareKeychain {
    private static let service = "nooppro.dexcomshare"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "account"]
    }

    @discardableResult
    static func save(_ c: DexcomShareCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> DexcomShareCredentials? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DexcomShareCredentials.self, from: data)
    }

    static func clear() { SecItemDelete(base as CFDictionary) }
}

/// Polls Dexcom Share. Sessions are cached and re-made on expiry; logins are rate-limited by Dexcom,
/// so a bad password stops polling instead of retrying into a lock-out.
actor DexcomShareClient {
    private var sessionId: String?
    private var blockedUntil: Date?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    func reset() { sessionId = nil; blockedUntil = nil }

    /// Readings from the last `minutes` (≤ 1440).
    func fetch(_ creds: DexcomShareCredentials, minutes: Int) async throws -> [GlucoseReading] {
        if let b = blockedUntil, b > Date() { throw DexcomShareError.badCredentials }
        let sid = try await ensureSession(creds)
        do {
            return try await read(creds.region, sid, minutes)
        } catch DexcomShareError.sessionExpired {
            sessionId = nil
            return try await read(creds.region, try await ensureSession(creds), minutes)
        }
    }

    /// Check credentials without keeping anything.
    func test(_ creds: DexcomShareCredentials) async throws -> Int {
        sessionId = nil
        blockedUntil = nil
        return try await fetch(creds, minutes: 60).count
    }

    private func read(_ region: DexcomShareRegion, _ sid: String, _ minutes: Int) async throws -> [GlucoseReading] {
        let (data, resp) = try await session.data(for: DexcomShareAPI.readingsRequest(region: region, sessionId: sid,
                                                                                      minutes: minutes, maxCount: 288))
        return try DexcomShareAPI.parseReadings(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func ensureSession(_ c: DexcomShareCredentials) async throws -> String {
        if let s = sessionId { return s }
        do {
            let (d1, r1) = try await session.data(for: DexcomShareAPI.authenticateRequest(region: c.region, username: c.username, password: c.password))
            let accountId = try DexcomShareAPI.parseId(d1, status: (r1 as? HTTPURLResponse)?.statusCode ?? 0)
            let (d2, r2) = try await session.data(for: DexcomShareAPI.loginByIdRequest(region: c.region, accountId: accountId, password: c.password))
            let sid = try DexcomShareAPI.parseId(d2, status: (r2 as? HTTPURLResponse)?.statusCode ?? 0)
            sessionId = sid
            return sid
        } catch let e as DexcomShareError {
            if e == .badCredentials || e == .accountNotFound { blockedUntil = Date().addingTimeInterval(30 * 60) }
            throw e
        }
    }
}
#endif
