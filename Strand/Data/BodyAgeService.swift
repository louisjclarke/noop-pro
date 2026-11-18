import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// NOOP Pro Body Age v2: the ONE place a week of data becomes a Body Age.
///
/// The weekly figure, the per-factor breakdown the Health screen lists, the 26-week history and the pace of
/// aging are all produced here from `VitalityEngine.weeklyInputs`, and the screen reads back what was
/// stored, so the number shown, the factors that explain it and the trend can never disagree.
///
/// Weekly rows are keyed by the Saturday on or before the window's last day (the key the original NOOP
/// engine used), so a row settles as its week ends. A window ending on day E reads:
///   • nightly signals (resting HR, HRV, sleep) from the 7 nights E−6 … E (a night is filed under the
///     morning it ended, so these are complete by the time the app runs that morning);
///   • daytime activity (zones, steps, strength) from the 7 COMPLETE days E−7 … E−1, so a half-finished
///     today never drags the week's activity down.
///
/// Stored under the computed ("my-whoop") source:
///   body_age, vitality, body_age_offset            (weekly)
///   body_age_f_<factor>  years that factor adds (+) or takes away (−)   (weekly)
///   body_age_v_<factor>  the factor's input value, for the breakdown     (weekly)
///   hr_zones13_min, hr_zones45_min, strength_min   (daily cache, heart-rate-reserve zones)
@MainActor
final class BodyAgeService: ObservableObject {
    static let shared = BodyAgeService()

    /// Bumped whenever the model changes scale; a mismatch rebuilds the stored history once.
    static let modelVersion = 2
    private static let modelKey = "nooppro.bodyAge.model"
    /// A VO₂ max the wearer measured (lab, watch test) and its entry date. Read for 365 days.
    static let measuredVO2Key = "nooppro.bodyAge.vo2Measured"
    static let measuredVO2DateKey = "nooppro.bodyAge.vo2MeasuredAt"

    struct Factor: Identifiable, Equatable {
        let key: String
        let label: String
        let value: Double?      // the input, nil = no data
        let years: Double?      // + older / − younger, nil = no data
        var id: String { key }
    }

    struct Snapshot: Equatable {
        let weekKey: String
        let bodyAge: Double
        let chronoAge: Double
        let vitality: Double
        let factors: [Factor]
        let clampYears: Double            // non-zero only when the ±25-year band cut the sum
        let pace: PaceOfAging.Result?
        let history: [HistoryPoint]
    }

    struct HistoryPoint: Equatable, Identifiable {
        let day: String
        let bodyAge: Double
        let chronoAge: Double
        var id: String { day }
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var loaded = false

    private weak var repo: Repository?
    private weak var profile: ProfileStore?
    private var lastRun = Date.distantPast
    private var task: Task<Void, Never>?
    private var subs = Set<AnyCancellable>()

    private init() {}

    func attach(repo: Repository, profile: ProfileStore) {
        self.repo = repo
        self.profile = profile
        repo.$days
            .dropFirst()
            .debounce(for: .seconds(20), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.schedule() } }
            .store(in: &subs)
        schedule(force: true, delaySeconds: 25)
    }

    /// Recompute at most every 30 minutes unless forced (a new VO₂ max, a profile edit, a manual refresh).
    func schedule(force: Bool = false, delaySeconds: Double = 1) {
        guard repo != nil, force || Date().timeIntervalSince(lastRun) > 1800 else { return }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.run()
        }
    }

    // MARK: Measured VO₂ max

    var measuredVO2: (value: Double, at: Date)? {
        let d = UserDefaults.standard
        let v = d.double(forKey: Self.measuredVO2Key)
        guard v > 0, let at = d.object(forKey: Self.measuredVO2DateKey) as? Date else { return nil }
        return (v, at)
    }

    func setMeasuredVO2(_ value: Double?) {
        let d = UserDefaults.standard
        if let value, value >= 15, value <= 95 {
            d.set(value, forKey: Self.measuredVO2Key)
            d.set(Date(), forKey: Self.measuredVO2DateKey)
        } else {
            d.removeObject(forKey: Self.measuredVO2Key)
            d.removeObject(forKey: Self.measuredVO2DateKey)
        }
        schedule(force: true)
    }

    // MARK: The pass

    private func run() async {
        guard let repo, let profile else { return }
        lastRun = Date()
        let rebuild = UserDefaults.standard.integer(forKey: Self.modelKey) != Self.modelVersion
        let today = Repository.localDayKey(Date())
        let sat = IntelligenceEngine.saturdayKey(onOrBefore: today)

        if rebuild {
            // A new model is on another scale: drop every stored week, then work out the last 26 again from
            // the data still held. A week with too little recorded is simply left out, never filled in. The
            // marker is written LAST so a pass cut short runs again.
            for key in ["body_age", "vitality", "body_age_offset"] + VitalityEngine.factorKeys.flatMap({ ["body_age_f_\($0)", "body_age_v_\($0)"] }) {
                await repo.deleteComputedSeries(key: key)
            }
            for weeksBack in stride(from: 25, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                let s = Self.addDays(sat, -7 * weeksBack)
                await computeAndStore(weekKey: s, windowEnd: Self.addDays(s, 6), repo: repo, profile: profile)
            }
        }
        guard !Task.isCancelled else { return }
        await computeAndStore(weekKey: sat, windowEnd: today, repo: repo, profile: profile)
        if rebuild { UserDefaults.standard.set(Self.modelVersion, forKey: Self.modelKey) }
        await loadSnapshot(repo: repo, profile: profile)
    }

    /// Build the week, run the engine and store the row. A week with fewer than 3 inputs stores nothing.
    private func computeAndStore(weekKey: String, windowEnd e: String, repo: Repository, profile: ProfileStore) async {
        let week = await weekData(windowEnd: e, repo: repo, profile: profile)
        let inputs = VitalityEngine.weeklyInputs(week)
        guard let r = VitalityEngine.compute(inputs) else { return }
        var pts: [MetricPoint] = [
            MetricPoint(day: weekKey, key: "body_age", value: r.bodyAge),
            MetricPoint(day: weekKey, key: "vitality", value: r.vitality),
            MetricPoint(day: weekKey, key: "body_age_offset", value: r.bodyAge - r.chronoAge),
        ]
        for c in r.contributions {
            pts.append(MetricPoint(day: weekKey, key: "body_age_f_\(c.key)", value: VitalityEngine.years(of: c)))
            if let v = Self.inputValue(c.key, inputs) {
                pts.append(MetricPoint(day: weekKey, key: "body_age_v_\(c.key)", value: v))
            }
        }
        // A factor that had data last pass but none now must not keep its old row for this week.
        let present = Set(r.contributions.map(\.key))
        for k in VitalityEngine.factorKeys where !present.contains(k) {
            await repo.deleteComputedPoint(day: weekKey, key: "body_age_f_\(k)")
            await repo.deleteComputedPoint(day: weekKey, key: "body_age_v_\(k)")
        }
        await repo.upsertExternalMetrics(pts, deviceId: repo.computedWriteId)
    }

    /// The input value the breakdown shows beside each factor.
    static func inputValue(_ key: String, _ i: VitalityEngine.Inputs) -> Double? {
        switch key {
        case "rhr": return i.restingHR
        case "hrv": return i.rmssd
        case "vo2max": return i.vo2max
        case "sleep": return i.sleepHours
        case "consistency": return i.sleepConsistency.map { $0 * 100 }
        case "steps": return i.steps
        case "zonesLow": return i.zonesLowMin
        case "zonesHigh": return i.zonesHighMin
        case "strength": return i.strengthMin
        case "leanMass": return i.leanMassPct
        case "glucose": return i.gmi
        default: return nil
        }
    }

    // MARK: One week of data

    private func weekData(windowEnd e: String, repo: Repository, profile: ProfileStore) async -> VitalityEngine.WeekData {
        let nightFrom = Self.addDays(e, -6)
        let actFrom = Self.addDays(e, -7), actTo = Self.addDays(e, -1)
        let daily = await repo.dailyMetrics(fromDay: actFrom, toDay: e)
        let byDay = Dictionary(daily.map { ($0.day, $0) }, uniquingKeysWith: { _, l in l })
        let nights = daily.filter { $0.day >= nightFrom && $0.day <= e }

        var w = VitalityEngine.WeekData(chronoAge: Self.exactAge(dob: profile.dateOfBirth, on: e),
                                        sex: profile.sex)
        w.restingHRs = nights.compactMap { $0.restingHr }.map(Double.init)
        w.rmssds = nights.compactMap { $0.avgHrv }.filter { $0 > 0 }
        w.sleepNights = nights.compactMap { $0.totalSleepMin }.map { $0 / 60 }.filter { $0 > 0 }

        // Steps: the phone's count where there is one, else the calibrated WHOOP 4.0 estimate.
        let est = Dictionary((await repo.computedSeries(key: "steps_est", from: actFrom, to: actTo)).map { ($0.day, $0.value) },
                             uniquingKeysWith: { _, l in l })
        let actDays = Self.days(from: actFrom, to: actTo)
        w.steps = actDays.compactMap { d in byDay[d]?.steps.map(Double.init) ?? est[d] }

        // Zones: the strap's own heart rate in heart-rate-reserve zones. Needs 4 worn days; fewer reads as
        // no data rather than a week of near-zero minutes, and 4–6 worn days are scaled to 7.
        let zones = await zoneMinutes(days: actDays, byDay: byDay, repo: repo, profile: profile)
        let worn = zones.filter { $0.value.worn }
        if worn.count >= 4 {
            let scale = 7 / Double(worn.count)
            w.zonesLowMin = worn.values.reduce(0) { $0 + $1.low } * scale
            w.zonesHighMin = worn.values.reduce(0) { $0 + $1.high } * scale
        }
        w.strengthMin = await strengthMinutes(days: actDays, repo: repo)

        // Cardio fitness: a measured VO₂ max from the last year wins, else the waist-based estimate. The
        // waist-free estimate is mostly resting HR, so reading it would count resting HR twice.
        if let m = measuredVO2, let eDate = Self.date(e), eDate.timeIntervalSince(m.at) < 365 * 86_400,
           eDate.timeIntervalSince(m.at) > -7 * 86_400 {
            w.cardioVO2 = m.value
        } else if profile.waistCm > 0 {
            w.cardioVO2 = (await repo.computedSeries(key: "vo2max_est", from: Self.addDays(e, -21), to: e)).last?.value
        }

        // Lean body mass: 100 − the mean body fat of the 90 days up to the window's end.
        let fat = await repo.exploreSeries(key: "body_fat", source: "apple-health", days: 4000)
            .filter { $0.day >= Self.addDays(e, -89) && $0.day <= e && $0.value > 2 && $0.value < 70 }
            .map(\.value)
        if !fat.isEmpty { w.leanMassPct = 100 - fat.reduce(0, +) / Double(fat.count) }

        // Glucose: the stored 14-day GMI nearest the window's end (it is only written with ≥ 10 days of CGM).
        w.gmi = (await repo.exploreSeries(key: "glucose_gmi", source: "dexcom-cgm", days: 4000))
            .filter { $0.day >= Self.addDays(e, -3) && $0.day <= e }.last?.value
        return w
    }

    private struct DayZones { let low: Double; let high: Double; let worn: Bool }

    /// Daily heart-rate-reserve zone minutes, cached as hr_zones13_min / hr_zones45_min so a week costs a
    /// handful of reads. The last 3 days are always re-read (a later sync can still add their heart rate).
    private func zoneMinutes(days: [String], byDay: [String: DailyMetric], repo: Repository,
                             profile: ProfileStore) async -> [String: DayZones] {
        guard let first = days.first, let last = days.last else { return [:] }
        let low = Dictionary((await repo.computedSeries(key: "hr_zones13_min", from: first, to: last)).map { ($0.day, $0.value) },
                             uniquingKeysWith: { _, l in l })
        let high = Dictionary((await repo.computedSeries(key: "hr_zones45_min", from: first, to: last)).map { ($0.day, $0.value) },
                              uniquingKeysWith: { _, l in l })
        let worn = Dictionary((await repo.computedSeries(key: "hr_worn_hours", from: first, to: last)).map { ($0.day, $0.value) },
                              uniquingKeysWith: { _, l in l })
        let fresh = Self.addDays(Repository.localDayKey(Date()), -3)
        let maxHR = profile.effortHRmax ?? 195
        let latestRest = repo.days.last(where: { $0.restingHr != nil })?.restingHr.map(Double.init) ?? 60
        var out: [String: DayZones] = [:]
        var writes: [MetricPoint] = []
        for d in days {
            if d < fresh, let l = low[d], let h = high[d], let wh = worn[d] {
                out[d] = DayZones(low: l, high: h, worn: wh >= 12)
                continue
            }
            guard let start = Self.date(d) else { continue }
            let from = Int(start.timeIntervalSince1970)
            let to = from + 86_400 - 1
            let samples = await repo.hrSamples(from: from, to: to, limit: 120_000)
            let rest = byDay[d]?.restingHr.map(Double.init) ?? latestRest
            let tiz = HRZones.timeInZone(samples, zoneSet: Self.reserveZones(maxHR: maxHR, resting: rest))
            let mins = tiz.seconds.map { $0 / 60 }
            let wornHours = (tiz.seconds.reduce(0, +) + tiz.belowZone1) / 3600
            let z = DayZones(low: mins[0] + mins[1] + mins[2], high: mins[3] + mins[4], worn: wornHours >= 12)
            out[d] = z
            writes += [MetricPoint(day: d, key: "hr_zones13_min", value: z.low),
                       MetricPoint(day: d, key: "hr_zones45_min", value: z.high),
                       MetricPoint(day: d, key: "hr_worn_hours", value: wornHours)]
        }
        if !writes.isEmpty { await repo.upsertExternalMetrics(writes, deviceId: repo.computedWriteId) }
        return out
    }

    /// WHOOP-style zones: 50/60/70/80/90 % of heart-rate reserve above that day's resting HR.
    static func reserveZones(maxHR: Double, resting: Double) -> HRZoneSet {
        let rest = min(max(resting, 30), maxHR - 20)
        let bounds = [0.5, 0.6, 0.7, 0.8, 0.9].map { rest + $0 * (maxHR - rest) }
        return HRZones.zones(maxHR: maxHR, source: "reserve", customLowerBounds: bounds)
    }

    /// Strength minutes from logged sessions whose sport is strength work, cached per day as strength_min.
    private func strengthMinutes(days: [String], repo: Repository) async -> Double {
        guard let first = days.first, let last = days.last,
              let from = Self.date(first)?.timeIntervalSince1970,
              let toDate = Self.date(last) else { return 0 }
        let to = toDate.timeIntervalSince1970 + 86_400
        let rows = await repo.workoutRows(days: 400).filter {
            Double($0.startTs) >= from && Double($0.startTs) < to && Self.isStrength(sport: $0.sport, source: $0.source)
        }
        var byDay: [String: Double] = [:]
        for r in rows {
            let mins = (r.durationS ?? Double(r.endTs - r.startTs)) / 60
            guard mins > 0, mins < 600 else { continue }
            byDay[Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(r.startTs))), default: 0] += mins
        }
        if !byDay.isEmpty {
            await repo.upsertExternalMetrics(byDay.map { MetricPoint(day: $0.key, key: "strength_min", value: $0.value) },
                                             deviceId: repo.computedWriteId)
        }
        return byDay.values.reduce(0, +)
    }

    static func isStrength(sport: String, source: String) -> Bool {
        let s = (sport + " " + source).lowercased()
        return ["strength", "weight", "lift", "gym", "crossfit", "resistance", "calisthenic", "functional"]
            .contains { s.contains($0) }
    }

    // MARK: Read back for the screen

    func loadSnapshot(repo: Repository, profile: ProfileStore) async {
        let from = Self.addDays(Repository.localDayKey(Date()), -200)
        let to = Self.addDays(Repository.localDayKey(Date()), 1)
        let ages = await repo.computedSeries(key: "body_age", from: from, to: to)
        guard let latest = ages.last else { snapshot = nil; loaded = true; return }
        let week = latest.day
        let vit = (await repo.computedSeries(key: "vitality", from: week, to: week)).last?.value ?? 50
        let offsets = await repo.computedSeries(key: "body_age_offset", from: from, to: to)
        var factors: [Factor] = []
        let labels = Dictionary(uniqueKeysWithValues: Self.factorLabels)
        for k in VitalityEngine.factorKeys {
            let y = (await repo.computedSeries(key: "body_age_f_\(k)", from: week, to: week)).last?.value
            let v = (await repo.computedSeries(key: "body_age_v_\(k)", from: week, to: week)).last?.value
            factors.append(Factor(key: k, label: labels[k] ?? k, value: y == nil ? nil : v, years: y))
        }
        let latestOffset = offsets.last(where: { $0.day == week })?.value ?? 0
        let chrono = latest.value - latestOffset
        let sum = factors.compactMap(\.years).reduce(0, +)
        let readings = offsets.compactMap { p -> PaceOfAging.Reading? in
            guard let d = Self.date(p.day) else { return nil }
            return PaceOfAging.Reading(time: d.timeIntervalSince1970, offset: p.value)
        }
        let offByDay = Dictionary(offsets.map { ($0.day, $0.value) }, uniquingKeysWith: { _, l in l })
        let history = ages.map { HistoryPoint(day: $0.day, bodyAge: $0.value, chronoAge: $0.value - (offByDay[$0.day] ?? 0)) }
        snapshot = Snapshot(weekKey: week, bodyAge: latest.value, chronoAge: chrono, vitality: vit,
                            factors: factors, clampYears: latestOffset - sum,
                            pace: PaceOfAging.compute(readings), history: history)
        loaded = true
    }

    /// Reload what is stored without recomputing (the screen calls this on appear).
    func reloadStored() async {
        guard let repo, let profile else { return }
        await loadSnapshot(repo: repo, profile: profile)
    }

    static let factorLabels: [(String, String)] = [
        ("rhr", String(localized: "Resting heart rate")),
        ("hrv", String(localized: "Heart-rate variability")),
        ("vo2max", String(localized: "Cardio fitness (VO₂ max)")),
        ("sleep", String(localized: "Sleep duration")),
        ("consistency", String(localized: "Sleep regularity")),
        ("steps", String(localized: "Daily steps")),
        ("zonesLow", String(localized: "Heart-rate zones 1–3")),
        ("zonesHigh", String(localized: "Heart-rate zones 4–5")),
        ("strength", String(localized: "Strength training")),
        ("leanMass", String(localized: "Lean body mass")),
        ("glucose", String(localized: "Glucose control (GMI)")),
    ]

    /// One line for the AI coach, or nil before the first weekly reading.
    func coachLine() -> String? {
        guard let s = snapshot else { return nil }
        var line = String(format: "Body Age (wellness estimate, weekly): %.1f years vs real age %.1f.", s.bodyAge, s.chronoAge)
        let ranked = s.factors.filter { $0.years != nil }.sorted { ($0.years ?? 0) < ($1.years ?? 0) }
        if let best = ranked.first, (best.years ?? 0) < 0 { line += String(format: " Helping most: %@ (%.1f y).", best.label, best.years ?? 0) }
        if let worst = ranked.last, (worst.years ?? 0) > 0 { line += String(format: " Holding back most: %@ (+%.1f y).", worst.label, worst.years ?? 0) }
        if let p = s.pace { line += String(format: " Pace of aging %.2fx (%@ confidence).", p.pace, p.confidence.rawValue) }
        return line
    }

    // MARK: Dates

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { fmt.date(from: day) }

    static func addDays(_ day: String, _ n: Int) -> String {
        guard let d = fmt.date(from: day),
              let r = Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: d) else { return day }
        return fmt.string(from: r)
    }

    static func days(from: String, to: String) -> [String] {
        var out: [String] = []
        var d = from
        while d <= to && out.count < 400 { out.append(d); d = addDays(d, 1) }
        return out
    }

    /// Age in fractional years on a day, from the date of birth, so a birthday is not a whole-year step.
    static func exactAge(dob: Date, on day: String) -> Double {
        guard let d = date(day) else { return 0 }
        return max(0, d.timeIntervalSince(dob) / (365.2425 * 86_400))
    }
}
