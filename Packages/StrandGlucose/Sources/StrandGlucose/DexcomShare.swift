import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dexcom Share ("Follow") — the relay the Dexcom app uploads to every 5 minutes when Share is on.
/// Used as the fallback when the phone is out of Bluetooth range of the sensor, or the Dexcom app is
/// running on a different phone. Unofficial: these are the endpoints the Follow app and open-source
/// projects (pydexcom, Nightscout share2nightscout-bridge) use. Credentials are the wearer's own and
/// live only in the iOS Keychain; this type never stores them.
public enum DexcomShareRegion: String, Codable, CaseIterable, Sendable {
    case outsideUS = "ous"   // UK and the rest of the world
    case us = "us"

    public var host: String {
        switch self {
        case .outsideUS: return "shareous1.dexcom.com"
        case .us: return "share2.dexcom.com"
        }
    }

    public var label: String { self == .outsideUS ? "Outside the US (UK, EU…)" : "United States" }
}

public enum DexcomShareError: Error, Equatable, CustomStringConvertible {
    case badCredentials
    case accountNotFound
    case sessionExpired
    case http(Int, String)
    case decode(String)

    public var description: String {
        switch self {
        case .badCredentials: return "Dexcom rejected the username or password."
        case .accountNotFound: return "No Dexcom account with that username in this region."
        case .sessionExpired: return "Dexcom session expired."
        case .http(let code, let body): return "Dexcom returned HTTP \(code): \(body.prefix(140))"
        case .decode(let what): return "Couldn't read Dexcom's reply (\(what))."
        }
    }
}

public enum DexcomShareAPI {
    /// The application id the Dexcom Share client identifies as.
    public static let applicationId = "d89443d2-327c-4a6f-89e5-496bbb0317db"
    static let nullUUID = "00000000-0000-0000-0000-000000000000"

    static func base(_ r: DexcomShareRegion) -> String { "https://\(r.host)/ShareWebServices/Services" }

    static func post(_ url: String, json: [String: String]?) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        if let json { req.httpBody = try? JSONSerialization.data(withJSONObject: json) }
        return req
    }

    public static func authenticateRequest(region: DexcomShareRegion, username: String, password: String) -> URLRequest {
        post("\(base(region))/General/AuthenticatePublisherAccount",
             json: ["accountName": username, "password": password, "applicationId": applicationId])
    }

    public static func loginByIdRequest(region: DexcomShareRegion, accountId: String, password: String) -> URLRequest {
        post("\(base(region))/General/LoginPublisherAccountById",
             json: ["accountId": accountId, "password": password, "applicationId": applicationId])
    }

    /// `minutes` max 1440, `maxCount` max 288 (one day of 5-minute readings).
    public static func readingsRequest(region: DexcomShareRegion, sessionId: String, minutes: Int = 1440, maxCount: Int = 288) -> URLRequest {
        let m = max(1, min(1440, minutes)), c = max(1, min(288, maxCount))
        return post("\(base(region))/Publisher/ReadPublisherLatestGlucoseValues?sessionId=\(sessionId)&minutes=\(m)&maxCount=\(c)",
                    json: nil)
    }

    /// Auth endpoints reply with a bare JSON string, e.g. `"3f2a…"`. Errors come back as an object
    /// with a `Code` field.
    public static func parseId(_ data: Data, status: Int) throws -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        if status != 200 { throw classify(body: body, status: status) }
        let id = body.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r"))
        guard !id.isEmpty, id != nullUUID else { throw DexcomShareError.badCredentials }
        return id
    }

    public static func parseReadings(_ data: Data, status: Int) throws -> [GlucoseReading] {
        let body = String(data: data, encoding: .utf8) ?? ""
        if status != 200 { throw classify(body: body, status: status) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DexcomShareError.decode("not an array")
        }
        var out: [GlucoseReading] = []
        for item in arr {
            guard let value = (item["Value"] as? NSNumber)?.doubleValue,
                  let wt = item["WT"] as? String ?? item["DT"] as? String,
                  let ts = parseDotNetDate(wt) else { continue }
            out.append(GlucoseReading(ts: ts, mgdl: value, ratePerMinute: trendRate(item["Trend"]),
                                      source: .dexcomShare, sensorId: nil))
        }
        return out.sorted { $0.ts < $1.ts }
    }

    static func classify(body: String, status: Int) -> DexcomShareError {
        if body.contains("SessionIdNotFound") || body.contains("SessionNotValid") { return .sessionExpired }
        if body.contains("AccountPasswordInvalid") || body.contains("SSO_AuthenticatePasswordInvalid") { return .badCredentials }
        if body.contains("AccountNotFound") || body.contains("SSO_AuthenticateAccountNotFound") { return .accountNotFound }
        if body.contains("MaxAttempts") { return .http(status, "Too many attempts — Dexcom has locked logins for a few minutes.") }
        return .http(status, body)
    }

    /// `/Date(1700000000000)/`, `Date(1700000000000+0000)` → unix seconds.
    public static func parseDotNetDate(_ s: String) -> Int? {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        var inner = String(s[s.index(after: open)..<close])
        if let sign = inner.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) { inner = String(inner[..<sign]) }
        guard let ms = Int64(inner) else { return nil }
        return Int(ms / 1000)
    }

    /// Share's trend is a word ("FortyFiveUp") on current servers and a 1…9 integer on old ones. Mapped
    /// to the midpoint of the arrow's mg/dL/min band.
    static func trendRate(_ raw: Any?) -> Double? {
        var key: String?
        if let s = raw as? String { key = s }
        if let n = raw as? NSNumber {
            key = ["", "DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown", "DoubleDown"]
                .indices.contains(n.intValue)
                ? ["", "DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown", "DoubleDown"][n.intValue]
                : nil
        }
        switch key {
        case "DoubleUp": return 3.5
        case "SingleUp": return 2.5
        case "FortyFiveUp": return 1.5
        case "Flat": return 0
        case "FortyFiveDown": return -1.5
        case "SingleDown": return -2.5
        case "DoubleDown": return -3.5
        default: return nil
        }
    }
}
