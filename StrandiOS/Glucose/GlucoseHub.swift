#if os(iOS)
import Foundation
import HealthKit
import SwiftUI
import UIKit
import WidgetKit
import StrandGlucose
import StrandAnalytics
import WhoopStore

/// Settings keys for NOOP Pro's glucose layer.
enum GlucosePrefs {
    static let bleEnabled = "nooppro.glucose.ble"
    static let shareEnabled = "nooppro.glucose.share"
    static let healthKitEnabled = "nooppro.glucose.healthkit"
    static let unit = "nooppro.glucose.unit"
    static let profile = "nooppro.glucose.profile"
    static let staleAlert = "nooppro.glucose.staleAlert"
    /// Opt-in wrist alerts: buzz the WHOOP when a live reading crosses these (mmol/L). A secondary nudge
    /// only — the Dexcom app's alarms stay the safety net.
    static let buzzLow = "nooppro.glucose.buzzLow"
    static let buzzLowMmol = "nooppro.glucose.buzzLowMmol"
    static let buzzHigh = "nooppro.glucose.buzzHigh"
    static let buzzHighMmol = "nooppro.glucose.buzzHighMmol"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            bleEnabled: true, shareEnabled: false, healthKitEnabled: true,
            unit: GlucoseUnit.mmol.rawValue, profile: GlucoseProfile.generalHealth.rawValue,
            buzzLow: false, buzzLowMmol: 3.9, buzzHigh: false, buzzHighMmol: 10.0,
        ])
    }
}

/// Everything the glucose screens show, computed off the main thread from the store + WHOOP data.
struct GlucoseAnalysis {
    var day: GlucoseSummary?
    var fortnight: GlucoseSummary?
    var agp: [GlucoseMetrics.AGPHour] = []
    var todayExcursions: [GlucoseExcursion] = []
    var fortnightExcursions: [GlucoseExcursion] = []
    var nights: [NightGlucose] = []
    var workouts: [WorkoutGlucose] = []
    var findings: [FusionFinding] = []
    var wholePicture: WholePictureDay?
    var dawnRise: Double?
    var dailyTIT: [DailyGlucoseRow] = []
    /// Today's high-stress hours with what glucose was doing in each.
    var stressContexts: [StressGlucoseContext] = []
    var stressSummary: String?
    /// Why last night's HRV / resting HR / sleep moved, from glucose.
    var lastNightExplanation: NightExplanation?
    /// Per wake-day explanations for the nights listed in `nights`.
    var nightExplanations: [Int: NightExplanation] = [:]
}

struct DailyGlucoseRow: Identifiable {
    var id: String { day }
    let day: String
    let tit: Double
    let mean: Double
    let cv: Double
}

/// Coordinates every glucose source and owns the merged series the UI reads.
@MainActor
final class GlucoseHub: ObservableObject {
    static let shared = GlucoseHub()

    @Published private(set) var latest: GlucoseReading?
    @Published private(set) var recent: [GlucoseReading] = []
    @Published private(set) var bleState: G7PassiveListener.State = .searching
    @Published private(set) var shareStatus: String = "Off"
    @Published private(set) var healthStatus: String = ""
    @Published private(set) var storedCount = 0
    @Published private(set) var analysis = GlucoseAnalysis()
    @Published private(set) var analysing = false
    /// Raised by the glucose widget's deep link.
    @Published var showGlucoseSheet = false
    @Published private(set) var lastBuzz: String?

    let store = GlucoseStore.shared
    private let ble = G7PassiveListener()
    private let share = DexcomShareClient()
    private let healthStore = HKHealthStore()
    private var shareTimer: Timer?
    private var started = false
    private weak var repo: Repository?
    private var buzzStrap: (() -> Void)?
    private var lastBuzzAt = Date.distantPast
    private var lastBuzzBand = 0
    private var lastAnalysis = Date.distantPast
    private var analysisTask: Task<Void, Never>?

    /// Called once at launch so glucose analysis (and everything it feeds: Explore metrics, Vitality,
    /// Whole Picture, the Coach) keeps running even when no glucose screen is open.
    func attach(repo: Repository, buzz: (() -> Void)? = nil) {
        self.repo = repo
        self.buzzStrap = buzz
        AICoachEngine.extraContextProvider = { [weak self] in self?.coachContext() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reload()
                await self.pollShare(force: false)
                self.scheduleAnalysis()
            }
        }
        scheduleAnalysis(force: true)
    }

    /// Re-run analysis at most every 10 minutes (or now, when forced), e.g. after new readings arrive.
    func scheduleAnalysis(force: Bool = false) {
        guard let repo, force || Date().timeIntervalSince(lastAnalysis) > 600 else { return }
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: force ? 3_000_000_000 : 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.analyse(repo: repo)
        }
    }

    private init() {
        GlucosePrefs.registerDefaults()
        ble.onReadings = { [weak self] r in self?.ingest(r) }
        ble.onState = { [weak self] s in self?.bleState = s }
    }

    var unit: GlucoseUnit { GlucoseUnit(rawValue: UserDefaults.standard.string(forKey: GlucosePrefs.unit) ?? "") ?? .mmol }
    var profile: GlucoseProfile { GlucoseProfile(rawValue: UserDefaults.standard.string(forKey: GlucosePrefs.profile) ?? "") ?? .generalHealth }

    /// Age of the latest value, seconds.
    var latestAge: Int? { latest.map { Int(Date().timeIntervalSince1970) - $0.ts } }

    func start() {
        guard !started else { return }
        started = true
        reload()
        applySettings()
    }

    /// Re-read every toggle and (re)start or stop the matching source.
    func applySettings() {
        let d = UserDefaults.standard
        if d.bool(forKey: GlucosePrefs.bleEnabled) { ble.start() } else { ble.stop(); bleState = .off }
        shareTimer?.invalidate()
        shareTimer = nil
        if d.bool(forKey: GlucosePrefs.shareEnabled), DexcomShareKeychain.load() != nil {
            shareStatus = "Waiting"
            shareTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollShare(force: false) }
            }
            Task { await pollShare(force: true) }
        } else {
            shareStatus = d.bool(forKey: GlucosePrefs.shareEnabled) ? "Add your Dexcom login" : "Off"
        }
        if d.bool(forKey: GlucosePrefs.healthKitEnabled) {
            Task { await importHealthKit(days: 3, interactive: false) }
        }
    }

    private func ingest(_ readings: [GlucoseReading]) {
        let before = latest?.ts ?? 0
        store.upsert(readings)
        reload()
        if let l = latest, l.ts > before { checkWristAlert(l) }
        scheduleAnalysis()
    }

    func reload() {
        let now = Int(Date().timeIntervalSince1970)
        recent = store.series(from: now - 86_400, to: now + 600)
        let changed = recent.last?.ts != latest?.ts
        latest = recent.last
        storedCount = store.count()
        if changed { publishWidget() }
    }

    /// Hand the latest value and a 3-hour trace to the glucose widget, then ask WidgetKit to redraw it.
    private func publishWidget() {
        guard let l = latest else { return }
        let now = Int(Date().timeIntervalSince1970)
        let trace = GlucoseSeries.slice(recent, from: now - 3 * 3600, to: now + 600).map(\.mgdl)
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let today = GlucoseMetrics.summary(GlucoseSeries.slice(recent, from: midnight, to: now + 600))
        GlucoseWidgetState(mgdl: l.mgdl, rate: l.ratePerMinute, ts: l.date, mmol: unit == .mmol,
                           targetLow: profile.targetLow, targetHigh: profile.targetHigh,
                           trace: trace, timeInTarget: today?.timeInTarget(profile)).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NOOPProGlucoseWidget")
    }

    /// Opt-in buzz on the strap when a fresh reading crosses a threshold. One buzz per crossing, then
    /// at most every 30 minutes while it stays out of range.
    private func checkWristAlert(_ r: GlucoseReading) {
        let d = UserDefaults.standard
        guard Int(Date().timeIntervalSince1970) - r.ts < 600, let buzz = buzzStrap else { return }
        let low = d.double(forKey: GlucosePrefs.buzzLowMmol) * mgdlPerMmol
        let high = d.double(forKey: GlucosePrefs.buzzHighMmol) * mgdlPerMmol
        var band = 0
        if d.bool(forKey: GlucosePrefs.buzzLow), r.mgdl < low { band = -1 }
        if d.bool(forKey: GlucosePrefs.buzzHigh), r.mgdl > high { band = 1 }
        defer { lastBuzzBand = band }
        guard band != 0 else { return }
        let newCrossing = band != lastBuzzBand
        guard newCrossing || Date().timeIntervalSince(lastBuzzAt) > 30 * 60 else { return }
        buzz()
        lastBuzzAt = Date()
        lastBuzz = "\(band < 0 ? "Low" : "High") buzz at \(Date().formatted(date: .omitted, time: .shortened)) (\(unit.format(r.mgdl)))"
    }

    /// Share is the fallback: skip the network when the sensor's own radio delivered in the last 7 min,
    /// unless forced (launch / pull-to-refresh), which back-fills any gap up to 24 h.
    func pollShare(force: Bool) async {
        guard UserDefaults.standard.bool(forKey: GlucosePrefs.shareEnabled), let creds = DexcomShareKeychain.load() else { return }
        let now = Int(Date().timeIntervalSince1970)
        if !force, let ble = store.latestTs(source: .g7Live), now - ble < 420 {
            shareStatus = "Standing by (Bluetooth is live)"
            return
        }
        let newest = max(store.latestTs(source: .dexcomShare) ?? 0, store.latestTs(source: .g7Live) ?? 0)
        let minutes = newest == 0 ? 1440 : min(1440, max(10, (now - newest) / 60 + 10))
        do {
            let r = try await share.fetch(creds, minutes: minutes)
            ingest(r)
            shareStatus = "OK · \(r.count) value\(r.count == 1 ? "" : "s") at \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            shareStatus = (error as? DexcomShareError)?.description ?? error.localizedDescription
        }
    }

    func testShare(_ c: DexcomShareCredentials) async -> String {
        do {
            let n = try await share.test(c)
            return "Connected — \(n) reading\(n == 1 ? "" : "s") in the last hour."
        } catch {
            return (error as? DexcomShareError)?.description ?? error.localizedDescription
        }
    }

    func resetShareSession() async { await share.reset() }

    @Published private(set) var healthImporting = false

    /// Dexcom writes to Apple Health with a 3-hour delay — useless live, ideal for history. Imports
    /// everything from the last `days`. `interactive` = the wearer tapped the button, so it may show
    /// the permission sheet; the launch-time top-up never does (no window exists that early, and an
    /// unpresentable sheet can leave the request pending forever).
    func importHealthKit(days: Int, interactive: Bool = true) async {
        guard !healthImporting else { return }
        guard HKHealthStore.isHealthDataAvailable() else { healthStatus = "Apple Health isn't available on this device."; return }
        guard HealthKitBridge.hasHealthKitEntitlement else {
            healthStatus = "This install has no Apple Health permission — the signing step removed it. Reinstall NOOP Pro through SideStore and keep app extensions, or use Dexcom Share for history."
            return
        }
        let type = HKQuantityType(.bloodGlucose)
        healthImporting = true
        defer { healthImporting = false }

        let status: HKAuthorizationRequestStatus = await withCheckedContinuation { cont in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: [type]) { s, _ in cont.resume(returning: s) }
        }
        if status != .unnecessary {
            guard interactive else { return }
            healthStatus = "Asking Apple Health for access…"
            let asked = await withTimeout(seconds: 60) { [healthStore] in
                try await healthStore.requestAuthorization(toShare: [], read: [type])
            }
            switch asked {
            case .timedOut:
                healthStatus = "Apple Health didn't respond. Close NOOP Pro fully, reopen it and tap Import again."
                return
            case .failed(let e):
                healthStatus = "Apple Health refused: \(e.localizedDescription)"
                return
            case .done:
                break
            }
        }

        healthStatus = "Reading \(days) days of glucose from Apple Health…"
        let start = Date().addingTimeInterval(-Double(days) * 86_400)
        let pred = HKQuery.predicateForSamples(withStart: start, end: Date())
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                cont.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(q)
        }
        let mgdlUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        let readings = samples.map {
            GlucoseReading(ts: Int($0.startDate.timeIntervalSince1970), mgdl: $0.quantity.doubleValue(for: mgdlUnit),
                           source: .appleHealth, sensorId: nil)
        }
        ingest(readings)
        if readings.isEmpty {
            // Apple Health returns an empty result (not an error) when read access is off.
            healthStatus = "Apple Health returned no glucose. Check: Health app → Browse → Blood Glucose shows Dexcom data, "
                + "and Settings → Health → Data Access & Devices → NOOP Pro → Blood Glucose is on. Then tap Import again."
        } else {
            healthStatus = "Imported \(readings.count) readings from Apple Health (last \(days) days)."
        }
    }

    enum TimedResult { case done, failed(Error), timedOut }

    private func withTimeout(seconds: Double, _ op: @escaping @Sendable () async throws -> Void) async -> TimedResult {
        await withTaskGroup(of: TimedResult.self) { group in
            group.addTask {
                do { try await op(); return .done } catch { return .failed(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    @Published private(set) var clarityStatus = ""

    /// Import a Dexcom Clarity CSV export (full history; works without Apple Health).
    func importClarity(url: URL) async {
        clarityStatus = "Reading \(url.lastPathComponent)…"
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            clarityStatus = "Couldn't open that file."
            return
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) { try ClarityImport.parse(text) }.value
            guard !result.readings.isEmpty else {
                clarityStatus = "No glucose readings found in that export."
                return
            }
            ingest(result.readings)
            let first = result.readings.first!.date.formatted(date: .abbreviated, time: .omitted)
            let last = result.readings.last!.date.formatted(date: .abbreviated, time: .omitted)
            clarityStatus = "Imported \(result.readings.count) readings (\(first) – \(last))."
            scheduleAnalysis(force: true)
        } catch {
            clarityStatus = (error as? ClarityImport.Failure)?.description ?? error.localizedDescription
        }
    }

    func addManual(mgdl: Double, at date: Date) {
        ingest([GlucoseReading(ts: Int(date.timeIntervalSince1970), mgdl: mgdl, source: .manual)])
    }

    // MARK: - Analysis

    func analyse(repo: Repository) async {
        guard !analysing else { return }
        analysing = true
        defer { analysing = false; lastAnalysis = Date() }
        let days = repo.days
        let sleeps = repo.sleeps
        let workouts = await repo.workoutRows(days: 30)
        let stressSeries = await repo.series(key: "stress", source: "my-whoop", days: 120)
        let stressToday = await StressDayCurve.today(repo: repo)
        let stressHours: [(startTs: Int, level: Double)] = stressToday?.result.hours.compactMap { h in
            h.level.map { (startTs: h.startTs, level: $0) }
        } ?? []
        let profile = self.profile
        let store = self.store
        let result: (GlucoseAnalysis, [MetricPoint]) = await Task.detached(priority: .userInitiated) {
            Self.compute(store: store, days: days, sleeps: sleeps, workouts: workouts, profile: profile,
                         stressByDay: Dictionary(stressSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a }),
                         stressHours: stressHours)
        }.value
        analysis = result.0
        // The Whole Picture's multi-vital pattern (which also counts overnight glucose) raises the same
        // once-a-day early-warning notification as NOOP's own illness watch, under the same switch.
        if UserDefaults.standard.bool(forKey: "behavior.illnessWatch"),
           result.0.wholePicture?.flags.contains(where: { $0.text.hasPrefix("Several vitals") }) == true {
            IllnessNotifier.post(String(localized: "Several of your vitals, including overnight glucose, are off your baseline together, a common early sign of illness or overreaching. Open Whole Picture for details."))
        }
        // Daily glucose figures become ordinary NOOP metrics (Explore, Compare, correlations).
        await repo.upsertExternalMetrics(result.1, deviceId: "dexcom-cgm")
    }

    nonisolated static func compute(store: GlucoseStore, days: [DailyMetric], sleeps: [CachedSleepSession],
                                    workouts: [WorkoutRow], profile: GlucoseProfile,
                                    stressByDay: [String: Double], stressHours: [(startTs: Int, level: Double)]) -> (GlucoseAnalysis, [MetricPoint]) {
        let now = Int(Date().timeIntervalSince1970)
        let cal = Calendar.current
        let series = store.series(from: now - 90 * 86_400, to: now + 600)
        var a = GlucoseAnalysis()
        let midnight = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let today = GlucoseSeries.slice(series, from: midnight, to: now + 600)
        let last24 = GlucoseSeries.slice(series, from: now - 86_400, to: now + 600)
        let last14 = GlucoseSeries.slice(series, from: now - 14 * 86_400, to: now + 600)
        a.day = GlucoseMetrics.summary(last24, windowSeconds: 86_400)
        a.fortnight = GlucoseMetrics.summary(last14, windowSeconds: 14 * 86_400)
        a.agp = GlucoseMetrics.agp(last14, calendar: cal)
        a.todayExcursions = GlucoseEvents.excursions(today)
        a.fortnightExcursions = GlucoseEvents.excursions(last14)
        a.dawnRise = GlucoseEvents.dawnRise(series, morning: Date(), calendar: cal)

        let nights = sleeps.map {
            FusionNight(startTs: $0.effectiveStartTs, endTs: $0.endTs, efficiency: $0.efficiency,
                        restingHr: $0.restingHr, avgHrv: $0.avgHrv)
        }
        a.nights = nights.filter { $0.endTs > now - 14 * 86_400 }
            .compactMap { GlucoseFusion.night($0, series: series) }
            .sorted { $0.night.startTs > $1.night.startTs }
        a.workouts = workouts.filter { $0.startTs > now - 30 * 86_400 }
            .map { FusionWorkout(startTs: $0.startTs, endTs: $0.endTs, sport: $0.sport, avgHr: $0.avgHr, strain: $0.strain) }
            .compactMap { GlucoseFusion.workout($0, series: series) }
            .sorted { $0.workout.startTs > $1.workout.startTs }

        let fdays = days.map {
            FusionDay(day: $0.day, recovery: $0.recovery, strain: $0.strain, hrv: $0.avgHrv, restingHr: $0.restingHr,
                      sleepMin: $0.totalSleepMin, skinTempDevC: $0.skinTempDevC, respRate: $0.respRateBpm,
                      spo2: $0.spo2Pct, steps: $0.steps, sleepEfficiency: $0.efficiency, deepMin: $0.deepMin,
                      disturbances: $0.disturbances, dayStress: stressByDay[$0.day])
        }.sorted { $0.day < $1.day }
        a.findings = GlucoseFusion.findings(series: series, days: fdays, nights: nights, calendar: cal)

        let daily = GlucoseFusion.dailySummaries(series, calendar: cal)
        a.dailyTIT = daily.keys.sorted().suffix(30).compactMap { k in
            daily[k].map { DailyGlucoseRow(day: k, tit: $0.timeInTarget(profile), mean: $0.mean, cv: $0.cv) }
        }
        // Stress × glucose: what glucose was doing in each of today's high-stress hours.
        a.stressContexts = GlucoseAttribution.stressHours(stressHours, series: series)
        a.stressSummary = GlucoseAttribution.stressSummary(a.stressContexts)

        // Sleep / HRV / resting HR × glucose: explain each recent night against personal baselines.
        func median(_ v: [Double]) -> Double? {
            let s = v.sorted(); guard !s.isEmpty else { return nil }
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let recentNights = nights.filter { $0.endTs > now - 30 * 86_400 }
        let baseHRV = median(recentNights.compactMap(\.avgHrv))
        let baseRHR = median(recentNights.compactMap { $0.restingHr.map(Double.init) })
        let nightMeans = a.nights.map(\.summary.mean)
        let overnightBaseline = nightMeans.count >= 5 ? median(Array(nightMeans.dropFirst())) : nil
        let strainByDay = Dictionary(fdays.compactMap { d in d.strain.map { (d.day, $0) } }, uniquingKeysWith: { a, _ in a })
        let typicalStrain = median(Array(strainByDay.values))
        for ng in a.nights {
            let startDay = GlucoseFusion.dayKey(Date(timeIntervalSince1970: TimeInterval(ng.night.startTs)), cal)
            a.nightExplanations[ng.night.startTs] = GlucoseAttribution.night(
                ng, baselineHRV: baseHRV, baselineRHR: baseRHR, overnightBaselineMean: overnightBaseline,
                priorDayStrain: strainByDay[startDay], typicalStrain: typicalStrain)
        }
        if let last = a.nights.first { a.lastNightExplanation = a.nightExplanations[last.night.startTs] }

        let todayKey = GlucoseFusion.dayKey(Date(), cal)
        let fusionToday = fdays.last(where: { $0.day == todayKey })
            ?? FusionDay(day: todayKey, recovery: nil, strain: nil, hrv: nil, restingHr: nil, sleepMin: nil)
        a.wholePicture = WholePicture.build(day: fusionToday, history: fdays, glucose: a.day,
                                            night: a.nights.first, profile: profile,
                                            overnightGlucoseBaseline: overnightBaseline,
                                            nightExplanation: a.lastNightExplanation)

        // Daily metrics for the shared metric store.
        var points: [MetricPoint] = []
        for (day, m) in GlucoseDailyMetrics.compute(series: series, nights: nights, calendar: cal) {
            for (k, v) in m where v.isFinite { points.append(MetricPoint(day: day, key: k, value: v)) }
        }
        return (a, points)
    }

    // MARK: - Coach context

    func coachContext() -> String? {
        guard let d = analysis.day else { return nil }
        let u = GlucoseUnit.mmol
        var lines = ["CONTINUOUS GLUCOSE (Dexcom G7, mmol/L; analysis only, never for treatment decisions):"]
        if let r = latest {
            let mins = max(0, (Int(Date().timeIntervalSince1970) - r.ts) / 60)
            lines.append("  now: \(u.format(r.mgdl)) \(r.trend?.arrow ?? "") (\(mins) min ago)")
        }
        lines.append("  last 24 h: mean \(u.format(d.mean)), CV \(Int(d.cv))%, time 3.9–7.8 \(Int(d.tight))%, "
                     + "time 3.9–10 \(Int(d.inRange))%, below 3.9 \(String(format: "%.1f", d.low + d.veryLow))%")
        if let f = analysis.fortnight {
            lines.append("  14 days: mean \(u.format(f.mean)), GMI \(String(format: "%.1f", f.gmi))%, CV \(Int(f.cv))%")
        }
        if !analysis.todayExcursions.isEmpty {
            let ex = analysis.todayExcursions.map { "+\(u.format($0.rise)) at \(Date(timeIntervalSince1970: TimeInterval($0.startTs)).formatted(date: .omitted, time: .shortened))" }
            lines.append("  today's rises: " + ex.joined(separator: ", "))
        }
        if let n = analysis.nights.first {
            lines.append("  last night: mean \(u.format(n.summary.mean)), lowest \(u.format(n.summary.min)), "
                         + "\(n.lows.count) low event(s)" + (n.lastRiseToSleepMinutes.map { ", last rise \(Int($0)) min before sleep" } ?? ""))
        }
        if let e = analysis.lastNightExplanation, !e.reasons.isEmpty {
            lines.append("  glucose and last night's recovery: " + e.reasons.joined(separator: " "))
        }
        if let s = analysis.stressSummary { lines.append("  stress × glucose: " + s) }
        let top = analysis.findings.prefix(5).map { "    - " + $0.sentence + " [\($0.confidence)]" }
        if !top.isEmpty {
            lines.append("  personal glucose↔body patterns:")
            lines.append(contentsOf: top)
        }
        return lines.joined(separator: "\n")
    }
}
#endif
