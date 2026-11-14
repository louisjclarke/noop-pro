#if os(iOS)
import Foundation
import HealthKit
import SwiftUI
import StrandGlucose
import WhoopStore

/// Settings keys for NOOP Pro's glucose layer.
enum GlucosePrefs {
    static let bleEnabled = "nooppro.glucose.ble"
    static let shareEnabled = "nooppro.glucose.share"
    static let healthKitEnabled = "nooppro.glucose.healthkit"
    static let unit = "nooppro.glucose.unit"
    static let profile = "nooppro.glucose.profile"
    static let staleAlert = "nooppro.glucose.staleAlert"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            bleEnabled: true, shareEnabled: false, healthKitEnabled: true,
            unit: GlucoseUnit.mmol.rawValue, profile: GlucoseProfile.generalHealth.rawValue,
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

    let store = GlucoseStore.shared
    private let ble = G7PassiveListener()
    private let share = DexcomShareClient()
    private let healthStore = HKHealthStore()
    private var shareTimer: Timer?
    private var started = false

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
            Task { await importHealthKit(days: 3) }
        }
    }

    private func ingest(_ readings: [GlucoseReading]) {
        store.upsert(readings)
        reload()
    }

    func reload() {
        let now = Int(Date().timeIntervalSince1970)
        recent = store.series(from: now - 86_400, to: now + 600)
        latest = recent.last
        storedCount = store.count()
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

    /// Dexcom writes to Apple Health with a 3-hour delay — useless live, ideal for history. Imports
    /// everything from the last `days`.
    func importHealthKit(days: Int) async {
        guard HKHealthStore.isHealthDataAvailable() else { healthStatus = "Apple Health unavailable"; return }
        let type = HKQuantityType(.bloodGlucose)
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [type])
        } catch {
            healthStatus = "Apple Health access not granted"
            return
        }
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
        healthStatus = "Imported \(readings.count) from Apple Health (last \(days) days)"
    }

    func addManual(mgdl: Double, at date: Date) {
        ingest([GlucoseReading(ts: Int(date.timeIntervalSince1970), mgdl: mgdl, source: .manual)])
    }

    // MARK: - Analysis

    func analyse(repo: Repository) async {
        guard !analysing else { return }
        analysing = true
        defer { analysing = false }
        let days = repo.days
        let sleeps = repo.sleeps
        let workouts = await repo.workoutRows(days: 30)
        let profile = self.profile
        let store = self.store
        let result: GlucoseAnalysis = await Task.detached(priority: .userInitiated) {
            Self.compute(store: store, days: days, sleeps: sleeps, workouts: workouts, profile: profile)
        }.value
        analysis = result
    }

    nonisolated static func compute(store: GlucoseStore, days: [DailyMetric], sleeps: [CachedSleepSession],
                                    workouts: [WorkoutRow], profile: GlucoseProfile) -> GlucoseAnalysis {
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
                      spo2: $0.spo2Pct, steps: $0.steps)
        }.sorted { $0.day < $1.day }
        a.findings = GlucoseFusion.findings(series: series, days: fdays, nights: nights, calendar: cal)

        let daily = GlucoseFusion.dailySummaries(series, calendar: cal)
        a.dailyTIT = daily.keys.sorted().suffix(30).compactMap { k in
            daily[k].map { DailyGlucoseRow(day: k, tit: $0.timeInTarget(profile), mean: $0.mean, cv: $0.cv) }
        }
        let todayKey = GlucoseFusion.dayKey(Date(), cal)
        let fusionToday = fdays.last(where: { $0.day == todayKey })
            ?? FusionDay(day: todayKey, recovery: nil, strain: nil, hrv: nil, restingHr: nil, sleepMin: nil)
        a.wholePicture = WholePicture.build(day: fusionToday, history: fdays, glucose: a.day,
                                            night: a.nights.first, profile: profile)
        return a
    }
}
#endif
