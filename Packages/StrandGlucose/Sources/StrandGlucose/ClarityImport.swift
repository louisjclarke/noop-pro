import Foundation

/// Dexcom Clarity CSV export → readings. Clarity (clarity.dexcom.eu / clarity.dexcom.com) exports
/// every sensor value with a header row like
///   Index, Timestamp (YYYY-MM-DDThh:mm:ss), Event Type, Event Subtype, Patient Info, Device Info,
///   Source Device ID, Glucose Value (mmol/L), Insulin Value (u), Carb Value (grams), Duration (hh:mm:ss),
///   Glucose Rate of Change (mmol/L/min), Transmitter Time (Long Integer), Transmitter ID
/// preceded by a few patient/device metadata rows. Only "EGV" rows (estimated glucose values) are
/// kept. Columns are found by name, so column order and the mg/dL vs mmol/L choice don't matter.
/// This is how NOOP Pro gets history on a free-Apple-ID install, where Apple Health is unavailable.
public enum ClarityImport {
    public struct Result: Equatable {
        public let readings: [GlucoseReading]
        public let skipped: Int
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notClarity
        public var description: String {
            "This doesn't look like a Dexcom Clarity export (no Timestamp / Event Type / Glucose Value columns)."
        }
    }

    public static func parse(_ text: String, timeZone: TimeZone = .current) throws -> Result {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
        guard let headerIdx = lines.firstIndex(where: { $0.contains("Timestamp") && $0.contains("Glucose Value") }) else {
            throw Failure.notClarity
        }
        let header = fields(lines[headerIdx])
        func col(_ needle: String) -> Int? { header.firstIndex { $0.localizedCaseInsensitiveContains(needle) } }
        guard let tCol = col("Timestamp"), let gCol = col("Glucose Value"), let eCol = col("Event Type") else {
            throw Failure.notClarity
        }
        let mmol = header[gCol].localizedCaseInsensitiveContains("mmol")
        let rCol = col("Rate of Change")
        let idCol = col("Transmitter ID")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let f2 = DateFormatter()
        f2.locale = f.locale; f2.timeZone = timeZone; f2.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var out: [GlucoseReading] = []
        var skipped = 0
        for line in lines[(headerIdx + 1)...] {
            let c = fields(line)
            guard c.count > max(tCol, gCol, eCol), c[eCol].caseInsensitiveCompare("EGV") == .orderedSame else { continue }
            guard let date = f.date(from: c[tCol]) ?? f2.date(from: c[tCol]) else { skipped += 1; continue }
            let raw = c[gCol]
            var mgdl: Double
            if raw.caseInsensitiveCompare("Low") == .orderedSame { mgdl = 40 }
            else if raw.caseInsensitiveCompare("High") == .orderedSame { mgdl = 400 }
            else if let v = Double(raw.replacingOccurrences(of: ",", with: ".")) { mgdl = mmol ? v * mgdlPerMmol : v }
            else { skipped += 1; continue }
            mgdl = (mgdl * 10).rounded() / 10
            var rate: Double? = nil
            if let rc = rCol, rc < c.count, let r = Double(c[rc].replacingOccurrences(of: ",", with: ".")) {
                rate = mmol ? r * mgdlPerMmol : r
            }
            let sensor = idCol.flatMap { $0 < c.count && !c[$0].isEmpty ? c[$0] : nil }
            out.append(GlucoseReading(ts: Int(date.timeIntervalSince1970), mgdl: mgdl, ratePerMinute: rate,
                                      source: .clarity, sensorId: sensor))
        }
        return Result(readings: out.sorted { $0.ts < $1.ts }, skipped: skipped)
    }

    /// Minimal CSV field splitter: commas, double-quoted fields, doubled quotes inside quotes.
    static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var it = Array(line)
        var i = 0
        while i < it.count {
            let ch = it[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 } else { inQuotes = false }
                } else { cur.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(ch)
            }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        it.removeAll()
        return out
    }
}
