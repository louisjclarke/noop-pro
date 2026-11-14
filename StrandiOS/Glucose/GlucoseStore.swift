#if os(iOS)
import Foundation
import SQLite3
import StrandGlucose

/// On-device glucose history: its own small SQLite file (Application Support/nooppro-glucose.sqlite),
/// deliberately separate from the WHOOP database so NOOP Pro's additions never touch upstream NOOP's
/// migrations or its Android-parity contract. Thread-confined to a private serial queue.
final class GlucoseStore {
    static let shared = GlucoseStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "nooppro.glucose.store")
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        queue.sync { open() }
    }

    private func open() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("nooppro-glucose.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS reading (
                ts INTEGER NOT NULL,
                source TEXT NOT NULL,
                mgdl REAL NOT NULL,
                rate REAL,
                sensor TEXT,
                PRIMARY KEY (ts, source)
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS reading_ts ON reading(ts);")
        // Protect the file at rest like the rest of the app's health data.
        try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Insert or replace. Returns the number of rows written.
    @discardableResult
    func upsert(_ readings: [GlucoseReading]) -> Int {
        guard !readings.isEmpty else { return 0 }
        return queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO reading (ts, source, mgdl, rate, sensor) VALUES (?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            exec("BEGIN;")
            var n = 0
            for r in readings {
                sqlite3_bind_int64(stmt, 1, Int64(r.ts))
                sqlite3_bind_text(stmt, 2, r.source.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, r.mgdl)
                if let rate = r.ratePerMinute { sqlite3_bind_double(stmt, 4, rate) } else { sqlite3_bind_null(stmt, 4) }
                if let s = r.sensorId { sqlite3_bind_text(stmt, 5, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
                if sqlite3_step(stmt) == SQLITE_DONE { n += 1 }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }
            exec("COMMIT;")
            return n
        }
    }

    /// Raw rows (every source) in [from, to), ascending.
    func readings(from: Int, to: Int) -> [GlucoseReading] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT ts, source, mgdl, rate, sensor FROM reading WHERE ts >= ? AND ts < ? ORDER BY ts;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(from))
            sqlite3_bind_int64(stmt, 2, Int64(to))
            var out: [GlucoseReading] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = Int(sqlite3_column_int64(stmt, 0))
                let src = GlucoseSource(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .manual
                let mgdl = sqlite3_column_double(stmt, 2)
                let rate: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
                let sensor: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
                out.append(GlucoseReading(ts: ts, mgdl: mgdl, ratePerMinute: rate, source: src, sensorId: sensor))
            }
            return out
        }
    }

    /// Merged one-value-per-5-minutes series, best source wins.
    func series(from: Int, to: Int) -> [GlucoseReading] {
        GlucoseSeries.withRates(GlucoseSeries.merge(readings(from: from, to: to)))
    }

    func latestTs(source: GlucoseSource) -> Int? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MAX(ts) FROM reading WHERE source = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, source.rawValue, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM reading;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func deleteAll() {
        queue.sync { _ = exec("DELETE FROM reading;") }
    }

    /// CSV of every stored row, for the wearer's own export.
    func csv() -> String {
        var lines = ["timestamp_utc,mgdl,mmol,rate_mgdl_per_min,source,sensor"]
        let f = ISO8601DateFormatter()
        for r in readings(from: 0, to: Int.max / 2) {
            lines.append([f.string(from: r.date), String(format: "%.0f", r.mgdl), String(format: "%.2f", r.mmol),
                          r.ratePerMinute.map { String(format: "%.2f", $0) } ?? "", r.source.rawValue, r.sensorId ?? ""]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
#endif
