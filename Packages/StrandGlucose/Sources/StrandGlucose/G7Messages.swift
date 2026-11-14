import Foundation

// Dexcom G7 / ONE+ passive-observation message decoders.
//
// Byte layouts are ported from LoopKit's G7SensorKit (MIT licence, © 2022 LoopKit Authors — see
// LICENSE-G7SensorKit-MIT in this package). NOOP Pro only *listens*: the Dexcom app on the same phone
// owns pairing and authentication, and every message here is decoded from notifications the sensor
// already sends to that app. Nothing in this package builds a frame to write to the sensor.

public enum G7UUID {
    public static let advertisementService = "FEBC"
    public static let cgmService = "F8083532-849E-531C-C594-30F1F86A4EA5"
    /// Write/Indicate — carries the 0x4E glucose message once the session is authenticated.
    public static let control = "F8083534-849E-531C-C594-30F1F86A4EA5"
    /// Write/Indicate — the Dexcom app's auth handshake; we only read its status echo.
    public static let authentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    /// Read/Write/Notify — 9-byte backfill records.
    public static let backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"

    /// G7 advertises "DXCMxx"; ONE+ advertises "DX02xx".
    public static func isDexcomSensorName(_ name: String?) -> Bool {
        guard let n = name else { return false }
        return n.hasPrefix("DXCM") || n.hasPrefix("DX02")
    }
}

public enum G7Opcode: UInt8 {
    case authChallengeRx = 0x05
    case sessionStopTx = 0x28
    case glucoseTx = 0x4e
    case extendedVersionTx = 0x52
    case backfillFinished = 0x59
}

/// The sensor's own algorithm state byte.
public enum G7AlgorithmState: Equatable, Sendable {
    case stopped, warmup, ok, temporaryIssue, expired, failed, other(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 1: self = .stopped
        case 2: self = .warmup
        case 6: self = .ok
        case 18: self = .temporaryIssue
        case 15, 24, 26: self = .expired
        case 11, 12, 16, 17, 19, 20, 21, 22, 25: self = .failed
        default: self = .other(raw)
        }
    }

    public var isReliable: Bool { self == .ok }

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .warmup: return "Warming up"
        case .ok: return "OK"
        case .temporaryIssue: return "Temporary sensor issue"
        case .expired: return "Session ended"
        case .failed: return "Sensor failed"
        case .other(let r): return "State \(r)"
        }
    }
}

@inline(__always) func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
@inline(__always) func le24(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) }
@inline(__always) func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
}

/// 0x4E — the live reading the sensor sends every 5 minutes.
///
///     0  1  2 3 4 5  6 7  8  9 1011 1213 14 15 1617 18
///          TTTTTTTT SQSQ       AGAG BGBG SS TR PRPR C
///  0x4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e
public struct G7GlucoseMessage: Equatable, Sendable {
    /// Seconds since sensor activation at which the *message* was sent.
    public let messageTimestamp: UInt32
    public let sequence: UInt16
    /// Seconds between the measurement and the radio packet.
    public let age: UInt16
    public let glucose: UInt16?
    public let predicted: UInt16?
    public let state: G7AlgorithmState
    /// mg/dL per minute.
    public let trend: Double?
    public let displayOnly: Bool

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 19, b[0] == G7Opcode.glucoseTx.rawValue, b[1] == 0 else { return nil }
        messageTimestamp = le32(b, 2)
        sequence = le16(b, 6)
        age = le16(b, 10)
        let g = le16(b, 12)
        glucose = g == 0xffff ? nil : g & 0x0fff
        displayOnly = g == 0xffff ? false : (b[18] & 0x10) != 0
        let p = le16(b, 16)
        predicted = p == 0xffff ? nil : p & 0x0fff
        state = G7AlgorithmState(raw: b[14])
        trend = b[15] == 0x7f ? nil : Double(Int8(bitPattern: b[15])) / 10
    }

    /// Seconds since activation of the measurement itself.
    public var glucoseTimestamp: UInt32 { messageTimestamp &- UInt32(age) }

    /// Activation time implied by this message, given when it arrived.
    public func activationDate(receivedAt: Date) -> Date {
        receivedAt.addingTimeInterval(-TimeInterval(messageTimestamp))
    }

    /// Convert to a reading, or nil when the sensor itself does not vouch for the value.
    public func reading(receivedAt: Date, sensorId: String?) -> GlucoseReading? {
        // Display-only values (e.g. during the G7's grace period) are kept: they are fine for analysis,
        // and NOOP Pro never presents a value as a treatment decision.
        guard let g = glucose, state.isReliable else { return nil }
        let measured = receivedAt.addingTimeInterval(-TimeInterval(age))
        return GlucoseReading(ts: Int(measured.timeIntervalSince1970), mgdl: Double(g), ratePerMinute: trend,
                              source: .g7Live, sensorId: sensorId)
    }
}

/// 9-byte backfill record.
///
///     0 1 2  3  4 5  6  7  8
///    TTTTTT    BGBG SS    TR
///    45a100 00 9600 06 0f fc
public struct G7BackfillMessage: Equatable, Sendable {
    public let timestamp: UInt32   // seconds since activation
    public let glucose: UInt16?
    public let state: G7AlgorithmState
    public let trend: Double?
    public let displayOnly: Bool

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count == 9 else { return nil }
        timestamp = le24(b, 0)
        let g = le16(b, 4)
        glucose = g == 0xffff ? nil : g & 0x0fff
        displayOnly = (b[7] & 0x10) != 0
        state = G7AlgorithmState(raw: b[6])
        trend = b[8] == 0x7f ? nil : Double(Int8(bitPattern: b[8])) / 10
    }

    public func reading(activation: Date, sensorId: String?) -> GlucoseReading? {
        guard let g = glucose, state.isReliable else { return nil }
        let ts = Int(activation.timeIntervalSince1970) + Int(timestamp)
        return GlucoseReading(ts: ts, mgdl: Double(g), ratePerMinute: trend, source: .g7Backfill, sensorId: sensorId)
    }
}

/// 0x05 on the authentication characteristic — the Dexcom app's handshake result. When it reports
/// bonded + authenticated it is safe to subscribe to the control characteristic.
public struct G7AuthStatus: Equatable, Sendable {
    public let isAuthenticated: Bool
    public let isBonded: Bool

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == G7Opcode.authChallengeRx.rawValue else { return nil }
        isAuthenticated = b[1] == 0x01
        isBonded = b[2] == 0x01
    }
}

/// 0x52 — session length / warm-up, which tells a 10-day G7 from a 15-day one.
public struct G7ExtendedVersion: Equatable, Sendable {
    public let sessionLength: TimeInterval
    public let warmupDuration: TimeInterval
    public let maxLifetimeDays: UInt16

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 15, b[0] == G7Opcode.extendedVersionTx.rawValue else { return nil }
        sessionLength = TimeInterval(le32(b, 2))
        warmupDuration = TimeInterval(le16(b, 6))
        maxLifetimeDays = le16(b, 13)
    }
}

/// Routes a raw notification from the control characteristic.
public enum G7ControlEvent: Equatable, Sendable {
    case glucose(G7GlucoseMessage)
    case extendedVersion(G7ExtendedVersion)
    case backfillFinished
    case sessionStopped
    case unknown(UInt8)

    public init?(data: Data) {
        guard let op = data.first else { return nil }
        switch G7Opcode(rawValue: op) {
        case .glucoseTx?:
            guard let m = G7GlucoseMessage(data: data) else { return nil }
            self = .glucose(m)
        case .extendedVersionTx?:
            guard let m = G7ExtendedVersion(data: data) else { return nil }
            self = .extendedVersion(m)
        case .backfillFinished?: self = .backfillFinished
        case .sessionStopTx?: self = .sessionStopped
        default: self = .unknown(op)
        }
    }
}
