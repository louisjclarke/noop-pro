import XCTest
@testable import StrandGlucose

final class G7DecodeTests: XCTestCase {
    func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    func testGlucoseMessage() throws {
        // Sample frame from LoopKit G7SensorKit's documentation comment.
        let m = try XCTUnwrap(G7GlucoseMessage(data: hex("4e00d50700000900000105006100060" + "1ffff0e")))
        XCTAssertEqual(m.messageTimestamp, 2005)
        XCTAssertEqual(m.sequence, 9)
        XCTAssertEqual(m.age, 5)
        XCTAssertEqual(m.glucose, 97)
        XCTAssertNil(m.predicted)
        XCTAssertEqual(m.state, .ok)
        XCTAssertEqual(m.trend ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(m.glucoseTimestamp, 2000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = try XCTUnwrap(m.reading(receivedAt: now, sensorId: "DXCM4K"))
        XCTAssertEqual(r.ts, 1_800_000_000 - 5)
        XCTAssertEqual(r.mgdl, 97)
        XCTAssertEqual(r.source, .g7Live)
    }

    func testGlucoseMessageFromSlice() throws {
        // Data slices keep their parent's indices; the decoder must not care.
        let parent = hex("aabb4e00d50700000900000105006100060" + "1ffff0e")
        let slice = parent[2...]
        XCTAssertEqual(G7GlucoseMessage(data: slice)?.glucose, 97)
    }

    func testControlRouting() {
        XCTAssertNotNil(G7ControlEvent(data: hex("4e00d50700000900000105006100060" + "1ffff0e")))
        XCTAssertEqual(G7ControlEvent(data: hex("59")), .backfillFinished)
        XCTAssertNil(G7GlucoseMessage(data: hex("4e01")))
    }

    func testBackfill() throws {
        let b = try XCTUnwrap(G7BackfillMessage(data: hex("45a10000960006" + "0ffc")))
        XCTAssertEqual(b.timestamp, 0x00a145)
        XCTAssertEqual(b.glucose, 150)
        XCTAssertEqual(b.state, .ok)
        XCTAssertEqual(b.trend ?? 0, -0.4, accuracy: 1e-9)
        let act = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(b.reading(activation: act, sensorId: nil)?.ts, 1_000_000 + 0x00a145)
    }

    func testExtendedVersion() throws {
        let v = try XCTUnwrap(G7ExtendedVersion(data: hex("5200406f1400880e00010a04ff1100")))
        XCTAssertEqual(v.maxLifetimeDays, 17)
        XCTAssertEqual(v.warmupDuration, 0x0e88)
    }

    func testAuth() {
        XCTAssertEqual(G7AuthStatus(data: hex("050101")), G7AuthStatus(data: hex("050101")))
        XCTAssertEqual(G7AuthStatus(data: hex("050101"))?.isBonded, true)
        XCTAssertNil(G7AuthStatus(data: hex("060101")))
    }

    func testSensorNames() {
        XCTAssertTrue(G7UUID.isDexcomSensorName("DXCM4K"))
        XCTAssertTrue(G7UUID.isDexcomSensorName("DX02AB"))
        XCTAssertFalse(G7UUID.isDexcomSensorName("WHOOP 4C1234"))
    }
}

final class ShareTests: XCTestCase {
    func testDates() {
        XCTAssertEqual(DexcomShareAPI.parseDotNetDate("Date(1700000000000)"), 1_700_000_000)
        XCTAssertEqual(DexcomShareAPI.parseDotNetDate("/Date(1700000000000+0000)/"), 1_700_000_000)
        XCTAssertNil(DexcomShareAPI.parseDotNetDate("nonsense"))
    }

    func testReadings() throws {
        let json = #"[{"WT":"Date(1700000600000)","ST":"Date(1700000600000)","DT":"Date(1700000600000+0000)","Value":110,"Trend":"Flat"},{"WT":"Date(1700000300000)","Value":104,"Trend":3}]"#
        let r = try DexcomShareAPI.parseReadings(Data(json.utf8), status: 200)
        XCTAssertEqual(r.map(\.mgdl), [104, 110])
        XCTAssertEqual(r[0].ratePerMinute, 1.5)
        XCTAssertEqual(r[1].trend, .flat)
    }

    func testIdAndErrors() throws {
        XCTAssertEqual(try DexcomShareAPI.parseId(Data("\"abc-123\"".utf8), status: 200), "abc-123")
        XCTAssertThrowsError(try DexcomShareAPI.parseId(Data("\"00000000-0000-0000-0000-000000000000\"".utf8), status: 200))
        XCTAssertThrowsError(try DexcomShareAPI.parseId(Data(#"{"Code":"AccountPasswordInvalid"}"#.utf8), status: 500)) { e in
            XCTAssertEqual(e as? DexcomShareError, .badCredentials)
        }
    }
}

final class MetricsTests: XCTestCase {
    func series(_ values: [Double], start: Int = 1_800_000_000, step: Int = 300) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(ts: start + $0.offset * step, mgdl: $0.element, source: .g7Live) }
    }

    func testFlatSeries() throws {
        let s = try XCTUnwrap(GlucoseMetrics.summary(series(Array(repeating: 100, count: 288))))
        XCTAssertEqual(s.mean, 100, accuracy: 1e-9)
        XCTAssertEqual(s.cv, 0, accuracy: 1e-9)
        XCTAssertEqual(s.inRange, 100)
        XCTAssertEqual(s.tight, 100)
        XCTAssertEqual(s.gri, 0)
        XCTAssertEqual(s.gmi, 3.31 + 2.392, accuracy: 1e-9)
        XCTAssertEqual(s.coverage, 1, accuracy: 0.01)
    }

    func testBands() throws {
        let s = try XCTUnwrap(GlucoseMetrics.summary(series([50, 60, 100, 200, 300])))
        XCTAssertEqual(s.veryLow, 20); XCTAssertEqual(s.low, 20); XCTAssertEqual(s.inRange, 20)
        XCTAssertEqual(s.high, 20); XCTAssertEqual(s.veryHigh, 20)
        XCTAssertEqual(s.gri, 100, accuracy: 1e-9)   // 156 before the 100 cap
    }

    func testRiskSign() {
        XCTAssertLessThan(GlucoseMetrics.risk(60), 0)
        XCTAssertGreaterThan(GlucoseMetrics.risk(250), 0)
        XCTAssertEqual(GlucoseMetrics.risk(112.5), 0, accuracy: 0.5)
    }

    func testMAGEOnSineWave() throws {
        // 100 ± 40 mg/dL over 6 h cycles: peak-to-nadir swing = 80.
        let v = (0..<288).map { 100 + 40 * sin(Double($0) / 72 * 2 * .pi) }
        let m = try XCTUnwrap(GlucoseMetrics.mage(series(v)))
        XCTAssertEqual(m, 80, accuracy: 6)
    }

    func testExcursionAndLow() {
        var v = Array(repeating: 90.0, count: 12)
        v += [100, 115, 135, 155, 165, 160, 145, 125, 110, 98, 92, 90]  // meal
        v += Array(repeating: 90.0, count: 6)
        v += [68, 62, 60, 64, 69, 85]                                    // 25-min low
        v += Array(repeating: 90.0, count: 6)
        let s = series(v)
        let ex = GlucoseEvents.excursions(s)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex.first?.peak, 165)
        XCTAssertEqual(ex.first?.baseline, 90)
        XCTAssertNotNil(ex.first?.recoveredTs)
        let lows = GlucoseEvents.lows(s)
        XCTAssertEqual(lows.count, 1)
        XCTAssertEqual(lows.first?.nadir, 60)
        XCTAssertFalse(lows.first?.isLevel2 ?? true)
    }

    func testMergePrefersBLE() {
        let a = GlucoseReading(ts: 1000, mgdl: 100, source: .dexcomShare)
        let b = GlucoseReading(ts: 1030, mgdl: 101, source: .g7Live)
        let c = GlucoseReading(ts: 1300, mgdl: 105, source: .appleHealth)
        let m = GlucoseSeries.merge([a, b, c])
        XCTAssertEqual(m.map(\.source), [.g7Live, .appleHealth])
    }

    func testInterpolation() {
        let s = series([100, 110])
        XCTAssertEqual(GlucoseSeries.value(at: 1_800_000_150, in: s) ?? 0, 105, accuracy: 1e-9)
        XCTAssertNil(GlucoseSeries.value(at: 1_700_000_000, in: s))
    }
}

final class FusionTests: XCTestCase {
    func testSpearmanMonotone() {
        let p: [(Double, Double)] = (0..<20).map { (Double($0), Double($0 * $0)) }
        XCTAssertEqual(GlucoseFusion.spearman(p), 1, accuracy: 1e-9)
    }

    func testFindingsDetectPlantedRelation() {
        // 30 days: on days whose previous day had a high mean glucose, recovery is lower.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day0 = 1_800_000_000 - 1_800_000_000 % 86_400
        var series: [GlucoseReading] = []
        var days: [FusionDay] = []
        for d in 0..<30 {
            let mean = 90.0 + Double((d * 37) % 50)
            for k in 0..<288 {
                series.append(GlucoseReading(ts: day0 + d * 86_400 + k * 300, mgdl: mean + Double(k % 5), source: .g7Live))
            }
            let key = GlucoseFusion.dayKey(Date(timeIntervalSince1970: TimeInterval(day0 + (d + 1) * 86_400)), cal)
            days.append(FusionDay(day: key, recovery: 100 - (mean - 90) * 1.2, strain: 10, hrv: 60, restingHr: 55, sleepMin: 450))
        }
        let f = GlucoseFusion.findings(series: series, days: days, nights: [], calendar: cal)
        let hit = f.first { $0.feature == "Day-before mean glucose" && $0.outcome == "recovery" }
        XCTAssertNotNil(hit)
        XCTAssertLessThan(hit?.rho ?? 0, -0.9)
    }

    func testWholePictureFlagsIllnessPattern() {
        let hist = (1...20).map { i in
            FusionDay(day: String(format: "2026-10-%02d", i), recovery: 70, strain: 12, hrv: 60 + Double(i % 3), restingHr: 50 + i % 2,
                      sleepMin: 470, skinTempDevC: 0, respRate: 14 + Double(i % 2) * 0.2)
        }
        let today = FusionDay(day: "2026-10-21", recovery: 30, strain: 6, hrv: 40, restingHr: 60, sleepMin: 400,
                              skinTempDevC: 0.8, respRate: 16)
        let wp = WholePicture.build(day: today, history: hist, glucose: nil, night: nil, profile: .generalHealth)
        XCTAssertEqual(wp.flags.first?.severity, .act)
        XCTAssertNotNil(wp.overall)
        XCTAssertTrue(wp.domains.contains { $0.name == "Nervous system" })
    }
}

final class AttributionTests: XCTestCase {
    func series(_ values: [Double], start: Int) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(ts: start + $0.offset * 300, mgdl: $0.element, source: .g7Live) }
    }

    func testStressHourDuringLowIsAttributedToGlucose() {
        let t0 = 1_800_000_000
        // Hour 1 steady at 95; hour 2 dips to 62.
        let s = series(Array(repeating: 95, count: 12) + [80, 72, 66, 62, 64, 70, 78, 85, 90, 92, 94, 95], start: t0)
        let ctx = GlucoseAttribution.stressHours([(t0, 2.4), (t0 + 3600, 2.6)], series: s)
        XCTAssertEqual(ctx.map(\.cause), [.steady, .low])
        XCTAssertNotNil(GlucoseAttribution.stressSummary(ctx))
    }

    func testLowStressHoursIgnored() {
        let t0 = 1_800_000_000
        let s = series(Array(repeating: 95, count: 12), start: t0)
        XCTAssertTrue(GlucoseAttribution.stressHours([(t0, 1.0)], series: s).isEmpty)
    }

    func testNightExplanationNamesTheLow() throws {
        let t0 = 1_800_000_000
        var v = Array(repeating: 100.0, count: 40)
        for i in 20..<26 { v[i] = 62 }
        let s = series(v, start: t0)
        let night = FusionNight(startTs: t0, endTs: t0 + 40 * 300, efficiency: 0.9, restingHr: 60, avgHrv: 40)
        let ng = try XCTUnwrap(GlucoseFusion.night(night, series: s))
        let e = GlucoseAttribution.night(ng, baselineHRV: 55, baselineRHR: 52, overnightBaselineMean: 100,
                                         priorDayStrain: 16, typicalStrain: 10)
        XCTAssertTrue(e.glucoseLikelyContributed)
        XCTAssertTrue(e.reasons.first?.hasPrefix("Glucose went low") ?? false)
        XCTAssertEqual(e.reasons.count, 2)  // low + after hard training
    }

    func testDailyMetrics() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day0 = 1_800_000_000 - 1_800_000_000 % 86_400
        let s = (0..<(288 * 12)).map { GlucoseReading(ts: day0 + $0 * 300, mgdl: 90 + Double($0 % 7), source: .g7Live) }
        let m = GlucoseDailyMetrics.compute(series: s, nights: [], calendar: cal)
        XCTAssertEqual(m.count, 12)
        let last = m[m.keys.sorted().last!]!
        XCTAssertEqual(last["glucose_mean"] ?? 0, 93 / mgdlPerMmol, accuracy: 0.05)
        XCTAssertNotNil(last["glucose_gmi"])
        XCTAssertNil(m[m.keys.sorted().first!]!["glucose_gmi"])   // < 10 days of history
    }

    func testSleepToGlucoseDirection() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day0 = 1_800_000_000 - 1_800_000_000 % 86_400
        var series: [GlucoseReading] = []
        var days: [FusionDay] = []
        for d in 0..<20 {
            let sleep = 360.0 + Double((d * 53) % 180)        // 6–9 h
            let mean = 130 - (sleep - 360) / 6                 // shorter sleep → higher glucose
            for k in 0..<288 { series.append(GlucoseReading(ts: day0 + d * 86_400 + k * 300, mgdl: mean + Double(k % 3), source: .g7Live)) }
            days.append(FusionDay(day: GlucoseFusion.dayKey(Date(timeIntervalSince1970: TimeInterval(day0 + d * 86_400)), cal),
                                  recovery: nil, strain: nil, hrv: nil, restingHr: nil, sleepMin: sleep))
        }
        let f = GlucoseFusion.findings(series: series, days: days, nights: [], calendar: cal)
        let hit = f.first { $0.feature == "Last night's sleep duration" && $0.outcome == "average glucose that day" }
        XCTAssertNotNil(hit)
        XCTAssertLessThan(hit?.rho ?? 0, -0.9)
    }
}

final class ClarityImportTests: XCTestCase {
    func testParsesMmolExport() throws {
        let csv = """
        Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mmol/L),Insulin Value (u),Carb Value (grams),Duration (hh:mm:ss),Glucose Rate of Change (mmol/L/min),Transmitter Time (Long Integer),Transmitter ID
        1,,FirstName,,Louis,,,,,,,,,
        2,,Device,,,"G7 Mobile App",iOS G7,,,,,,,
        3,2026-11-10T08:00:00,EGV,,,,iOS G7,5.6,,,,0.1,12345,DXCM4K
        4,2026-11-10T08:05:00,EGV,,,,iOS G7,Low,,,,,12645,DXCM4K
        5,2026-11-10T08:10:00,Alert,High,,,iOS G7,,,,,,,
        6,2026-11-10T08:15:00,EGV,,,,iOS G7,"6,1",,,,,12945,DXCM4K
        """
        let r = try ClarityImport.parse(csv, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(r.readings.count, 3)
        XCTAssertEqual(r.readings[0].mgdl, 100.9, accuracy: 0.05)
        XCTAssertEqual(r.readings[1].mgdl, 40)
        XCTAssertEqual(r.readings[2].mgdl, 109.9, accuracy: 0.05)
        XCTAssertEqual(r.readings[0].sensorId, "DXCM4K")
        XCTAssertEqual(r.readings[0].source, .clarity)
        XCTAssertEqual(r.readings[0].ts, 1_794_297_600)
    }

    func testMgdlExportAndRejection() throws {
        let csv = "Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Glucose Value (mg/dL)\n1,2026-11-10T08:00:00,EGV,101"
        XCTAssertEqual(try ClarityImport.parse(csv, timeZone: TimeZone(identifier: "UTC")!).readings.first?.mgdl, 101)
        XCTAssertThrowsError(try ClarityImport.parse("a,b,c\n1,2,3"))
    }
}
