import Foundation

// VitalityEngine.swift — a transparent 0–100 "Vitality" wellness score + an optional "Body Age in years".
//
// INDEPENDENT implementation of the published, peer-reviewed method WHOOP's "Healthspan / WHOOP Age" also
// uses (NOT medical advice; a wellness comparison, never a clinical biological age): map each wearable-
// measurable input to its published ALL-CAUSE-MORTALITY hazard ratio relative to a population reference,
// sum the log-hazards with an overlap correction (the inputs are correlated, so the naive sum overstates),
// and convert that combined hazard into a "years of aging" offset using the Gompertz mortality-rate
// doubling time (mortality roughly doubles every ~8 years, so 1 doubling of hazard ≈ 8 years of age).
//
// Body Age = chronological age + Δage. An average-for-their-age person nets ~0 and reads at their own age;
// healthier-than-average reads younger, less healthy reads older. Presented with a ±band and a hard
// "wellness trend, not a biological/clinical age" disclaimer, gated on a minimum number of inputs.
//
// Per-factor hazard ratios are taken from large cohorts / meta-analyses (UK Biobank, FRIEND, pooled
// step- and activity-mortality meta-analyses, sleep-regularity and HRV cohorts). They are deliberately
// CONSERVATIVE and the model is clamped, because this is a wellness estimate, not a diagnosis.
public enum VitalityEngine {

    // Gompertz: mortality-rate doubling time ≈ 8 years → ln(hazard) per year of age = ln(2)/8.
    static let lnHazardPerYear = 0.6931471805599453 / 8.0   // ≈ 0.0866
    /// Correlated inputs (fitness, RHR, activity all move together) → shrink the naive log-hazard sum so
    /// we don't multiply the same underlying signal several times. 0.75 is a deliberately gentle shrink.
    static let overlapShrink = 0.75
    /// Body Age is clamped to a sane band; Vitality maps Δage linearly around 50 (= "at your age").
    /// NOOP Pro: the band is ALSO relative to the wearer's own age (±`maxOffsetYears`). The old absolute
    /// floor of 20 meant anyone under 20 could never read younger than 20, so an 18-year-old always read
    /// at least two years "older" whatever their data said.
    static let minBodyAge = 10.0, maxBodyAge = 100.0
    public static let maxOffsetYears = 25.0
    static let vitalityPerYear = 2.5   // each year younger than your age = +2.5 Vitality points

    /// The wearable inputs Vitality reads. All optional — the score uses whatever is present (≥ minFactors).
    public struct Inputs: Equatable, Sendable {
        public var chronoAge: Double
        public var restingHR: Double?          // bpm
        public var vo2max: Double?             // ml/kg/min (e.g. from FitnessAgeEngine)
        public var expectedVO2max: Double?     // age/sex-expected ml/kg/min (the reference for vo2max)
        public var sleepHours: Double?         // mean nightly sleep
        public var sleepConsistency: Double?   // 0–1 regularity (1 = perfectly regular)
        public var rmssd: Double?              // ms, nocturnal HRV
        public var rmssdNorm: Double?          // age/sex-normative RMSSD (the reference)
        public var steps: Double?              // mean daily steps
        /// NOOP Pro: Glucose Management Indicator (%), the CGM estimate of HbA1c over ≥ 10–14 days.
        /// nil on builds/users without a CGM, which leaves every other factor byte-identical.
        public var gmi: Double?
        /// NOOP Pro Body Age v2: weekly minutes in heart-rate-reserve zones 1–3 and 4–5, weekly strength
        /// minutes, and lean body mass (% of body weight). nil = no data (never read as zero).
        public var zonesLowMin: Double?
        public var zonesHighMin: Double?
        public var strengthMin: Double?
        public var leanMassPct: Double?
        /// "male" / "female" / anything else. Only the lean-mass break-even reads it.
        public var sex: String
        public init(chronoAge: Double, restingHR: Double? = nil, vo2max: Double? = nil,
                    expectedVO2max: Double? = nil, sleepHours: Double? = nil,
                    sleepConsistency: Double? = nil, rmssd: Double? = nil,
                    rmssdNorm: Double? = nil, steps: Double? = nil, gmi: Double? = nil,
                    zonesLowMin: Double? = nil, zonesHighMin: Double? = nil,
                    strengthMin: Double? = nil, leanMassPct: Double? = nil, sex: String = "") {
            self.chronoAge = chronoAge; self.restingHR = restingHR; self.vo2max = vo2max
            self.expectedVO2max = expectedVO2max; self.sleepHours = sleepHours
            self.sleepConsistency = sleepConsistency; self.rmssd = rmssd
            self.rmssdNorm = rmssdNorm; self.steps = steps; self.gmi = gmi
            self.zonesLowMin = zonesLowMin; self.zonesHighMin = zonesHighMin
            self.strengthMin = strengthMin; self.leanMassPct = leanMassPct; self.sex = sex
        }
    }

    /// One factor's contribution: its label and signed log-hazard vs the population reference
    /// (positive = ages you, negative = protective).
    public struct Contribution: Equatable, Sendable {
        public let key: String
        public let label: String
        public let lnHazard: Double
        public init(key: String, label: String, lnHazard: Double) {
            self.key = key; self.label = label; self.lnHazard = lnHazard
        }
    }

    public struct Result: Equatable, Sendable {
        public let vitality: Double        // 0–100 (50 = typical for your age)
        public let bodyAge: Double         // years, clamped
        public let chronoAge: Double
        public let deltaYears: Double      // chronoAge − bodyAge (positive = younger than your age)
        public let bandYears: Double
        public let contributions: [Contribution]   // for the "what's driving this" breakdown
        public let factorsUsed: Int
        public init(vitality: Double, bodyAge: Double, chronoAge: Double, deltaYears: Double,
                    bandYears: Double, contributions: [Contribution], factorsUsed: Int) {
            self.vitality = vitality; self.bodyAge = bodyAge; self.chronoAge = chronoAge
            self.deltaYears = deltaYears; self.bandYears = bandYears
            self.contributions = contributions; self.factorsUsed = factorsUsed
        }
    }

    /// Minimum distinct factors before we'll show a number (honesty gate).
    public static let minFactors = 3
    public static let bandYears = 5.0

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// Nocturnal RMSSD ~50th-percentile by age (ms), piecewise-linear between decade anchors (the WHOOP-
    /// window norms banked in the spec — never mixed with daytime clinical norms). The reference for the
    /// HRV factor: a person at the age norm contributes 0.
    public static func rmssdNorm(forAge age: Double) -> Double {
        let anchors: [(Double, Double)] = [(20, 47), (30, 40), (40, 33), (50, 29), (60, 25), (70, 22), (80, 20)]
        if age <= anchors[0].0 { return anchors[0].1 }
        if age >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }
        for i in 1..<anchors.count where age <= anchors[i].0 {
            let (a0, v0) = anchors[i - 1]; let (a1, v1) = anchors[i]
            return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
        }
        return anchors[anchors.count - 1].1
    }

    /// Sleep regularity (0–1) from a window of nightly sleep durations (hours): 1 − coefficient of
    /// variation, clamped. A rough but honest on-device proxy for the Sleep Regularity Index when we only
    /// have durations, not full timing. Fewer than 3 nights → nil (not enough to judge).
    public static func sleepConsistency(nightlyHours: [Double]) -> Double? {
        let xs = nightlyHours.filter { $0 > 0 }
        guard xs.count >= 3 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        let cv = variance.squareRoot() / mean
        return clamp(1 - cv, 0, 1)
    }

    /// Compute the per-factor log-hazard contributions present in `inputs`. Each references a population
    /// value, so an average person nets ~0. Published per-unit hazard ratios (conservative, clamped):
    ///   • Resting HR: +~10.5% all-cause mortality per +10 bpm (UK Biobank / meta-analyses). ref
    ///     `restingHRBreakEven` (60): the strap reads resting HR ASLEEP, which runs several bpm under the
    ///     seated daytime readings the cohorts used (population ~65–70), so 60 is the like-for-like neutral.
    ///   • VO₂max: ~14% per MET (3.5 ml/kg/min) vs the age/sex-expected value (FRIEND). fitter = protective.
    ///   • Sleep duration: U-shaped, optimum ~7.5 h; only deviation beyond ±0.5 h adds hazard (~12%/h).
    ///   • Sleep regularity: most-regular vs least ≈ HR 0.70 (UK Biobank SRI). ref 0.75 of the 0–1 range.
    ///   • HRV (RMSSD): ~16% per relative SD below the age norm (lower HRV = higher hazard).
    ///   • Steps: ~12% per 1,000 steps/day up to ~7k, diminishing to ~11k (pooled step-mortality meta).
    public static func contributions(_ inputs: Inputs) -> [Contribution] {
        var out: [Contribution] = []
        if let rhr = inputs.restingHR {
            out.append(Contribution(key: "rhr", label: "Resting heart rate",
                                    lnHazard: ((rhr - restingHRBreakEven) / 10) * 0.100))
        }
        if let vo2 = inputs.vo2max, let exp = inputs.expectedVO2max, exp > 0 {
            // (expected − vo2): if fitter than expected this is negative → protective.
            out.append(Contribution(key: "vo2max", label: "Cardio fitness",
                                    lnHazard: clamp((exp - vo2) / 3.5, -4, 4) * 0.130))
        }
        if let sh = inputs.sleepHours {
            let dev = max(0, abs(sh - 7.5) - 0.5)   // only deviation > ±0.5 h is a risk; optimum is neutral
            out.append(Contribution(key: "sleep", label: "Sleep duration",
                                    lnHazard: clamp(dev, 0, 3) * 0.110))
        }
        if let c = inputs.sleepConsistency {
            out.append(Contribution(key: "consistency", label: "Sleep regularity",
                                    lnHazard: (0.75 - clamp(c, 0, 1)) * 0.450))
        }
        if let h = inputs.rmssd, let norm = inputs.rmssdNorm, norm > 0 {
            out.append(Contribution(key: "hrv", label: "Heart-rate variability",
                                    lnHazard: clamp((norm - h) / norm, -1, 1) * 0.160))
        }
        if let s = inputs.steps {
            // Below ~7k each −1,000 steps adds hazard; protection caps near 11k (diminishing returns).
            let deficit = (7000 - clamp(s, 0, 11000)) / 1000
            out.append(Contribution(key: "steps", label: "Daily steps",
                                    lnHazard: clamp(deficit, -4, 4) * 0.064))
        }
        if let g = inputs.gmi {
            // NOOP Pro. Glycaemia and all-cause mortality in adults without diagnosed diabetes is J-shaped
            // with the minimum around HbA1c 5.0–5.5% and risk climbing above ~5.7% (ARIC; Selvin et al.,
            // NEJM 2010). Conservative: only the rising arm (above 5.7%) adds hazard, ~0.30 ln-hazard per
            // percentage point, clamped. A low GMI is NOT scored as protective — a CGM-derived GMI is an
            // estimate, and very low values usually mean lows rather than better health.
            out.append(Contribution(key: "glucose", label: "Glucose control",
                                    lnHazard: clamp(g - 5.7, 0, 3) * 0.30))
        }
        if let m = inputs.zonesLowMin {
            out.append(Contribution(key: "zonesLow", label: "Heart-rate zones 1–3",
                                    lnHazard: lowZoneEffect(m) - lowZoneEffect(lowZoneBreakEven)))
        }
        if let m = inputs.zonesHighMin {
            out.append(Contribution(key: "zonesHigh", label: "Heart-rate zones 4–5",
                                    lnHazard: highZoneEffect(m) - highZoneEffect(highZoneBreakEven)))
        }
        if let m = inputs.strengthMin {
            out.append(Contribution(key: "strength", label: "Strength training",
                                    lnHazard: strengthEffect(m) - strengthEffect(strengthBreakEven)))
        }
        if let l = inputs.leanMassPct {
            out.append(Contribution(key: "leanMass", label: "Lean body mass",
                                    lnHazard: leanMassEffect(leanPct: l, sex: inputs.sex)))
        }
        return out
    }

    // MARK: NOOP Pro Body Age v2 — the activity and body-composition factors
    //
    // Each activity factor is an absolute log-hazard curve over minutes per week; the contribution is the
    // curve at the wearer's minutes minus the curve at the break-even, so someone exactly at the break-even
    // adds nothing. The curves are a CONSERVATIVE reading of the cited cohorts, not a re-fit: those measured
    // self-reported moderate/vigorous minutes, these are minutes in heart-rate-reserve zones, so the match is
    // approximate and these are the least certain factors. The global overlap shrink also keeps them from
    // counting the same activity twice with steps.

    /// Sleep-measured resting HR at which the resting-HR factor is neutral (see `contributions`).
    public static let restingHRBreakEven = 60.0
    /// Weekly minutes at which each activity factor reads neutral. Zones 1–3: where the Wen 2011 curve first
    /// bends (~15 min/day). Zones 4–5: a few minutes a week. Strength: the middle of Momma 2022's 30–60 min.
    public static let lowZoneBreakEven = 92.0, highZoneBreakEven = 10.0, strengthBreakEven = 45.0

    /// Zones 1–3 (Wen et al., Lancet 2011): the first ~92 min/week of moderate activity lowers all-cause
    /// mortality ~14%, each further ~92 min ~4% more; flat beyond 10 h/week.
    public static func lowZoneEffect(_ minutesPerWeek: Double) -> Double {
        let m = clamp(minutesPerWeek, 0, 600)
        return -0.151 * min(m, 92) / 92 - 0.040 * max(0, m - 92) / 92
    }

    /// Zones 4–5: an extra ~13% lower hazard by two hours a week of vigorous activity on top of the moderate
    /// curve (the direction of Arem 2015 and Stamatakis 2022; a deliberately small reading of their size).
    public static func highZoneEffect(_ minutesPerWeek: Double) -> Double {
        -0.0012 * clamp(minutesPerWeek, 0, 120)
    }

    /// Strength (Momma et al., BJSM 2022): 30–60 min/week of muscle-strengthening goes with ~10–17% lower
    /// all-cause mortality and no further gain past about an hour.
    public static func strengthEffect(_ minutesPerWeek: Double) -> Double {
        -0.12 * min(clamp(minutesPerWeek, 0, 600), 60) / 60
    }

    /// Body fat (%) above which the lean-mass factor starts to add years: the widely used obesity cut-offs
    /// of 25% for men and 32% for women (the midpoint for anyone else). Below it the factor is neutral; a
    /// very lean body is NOT scored as protective.
    public static func bodyFatBreakEven(sex: String) -> Double {
        switch sex.lowercased() {
        case "male": return 25
        case "female": return 32
        default: return 28.5
        }
    }

    /// Lean body mass factor. Body fat above the sex-specific break-even adds 0.02 ln-hazard per point,
    /// capped at 15 points (at most +0.30 ln-hazard, ≈ +2.6 years after the overlap shrink). A conservative
    /// reading of the J-shaped body-fat / mortality curves (Padwal et al., Ann Intern Med 2016; UK Biobank),
    /// whose top-vs-reference hazard ratios are ~1.2–1.4. LOWER CONFIDENCE than the heart and activity factors.
    public static func leanMassEffect(leanPct: Double, sex: String) -> Double {
        let fat = 100 - clamp(leanPct, 0, 100)
        return 0.02 * clamp(fat - bodyFatBreakEven(sex: sex), 0, 15)
    }

    /// The median VO₂ max (ml/kg/min) for an age and sex: the FRIEND registry 50th percentile (Kaminsky et
    /// al., Mayo Clin Proc 2015), a straight line between 20–29 (men 48.0, women 37.6, at 25) and 70–79
    /// (men 24.4, women 18.3, at 75). Any other sex reads the mean of the two. Ages outside 20–80 clamp.
    public static func expectedVO2max(age: Double, sex: String) -> Double {
        let a = clamp(age, 20, 80)
        func line(_ at25: Double, _ at75: Double) -> Double { at25 + (at75 - at25) * (a - 25) / 50 }
        let men = line(48.0, 24.4), women = line(37.6, 18.3)
        switch sex.lowercased() {
        case "male": return men
        case "female": return women
        default: return (men + women) / 2
        }
    }

    /// The years a contribution adds (+, older) or takes away (−, younger) exactly as `compute` counts it,
    /// after the overlap shrink, so a list of factors sums to the Body Age offset (before any clamp).
    public static func years(of contribution: Contribution) -> Double {
        contribution.lnHazard * overlapShrink / lnHazardPerYear
    }

    /// Every factor key Body Age v2 can read, in display order.
    public static let factorKeys = ["rhr", "hrv", "vo2max", "sleep", "consistency", "steps",
                                    "zonesLow", "zonesHigh", "strength", "leanMass", "glucose"]

    // MARK: One week of data → inputs (the ONE reader the weekly job, the history rebuild and the screen use)

    /// What one week hands Body Age before any of it is averaged. Built once per week by the app and fed to
    /// `weeklyInputs`, so the number stored, the factors listed and the history all come from one function.
    public struct WeekData: Equatable, Sendable {
        public var chronoAge: Double
        public var sex: String
        public var restingHRs: [Double]
        public var rmssds: [Double]
        public var sleepNights: [Double]          // hours asleep, one per night
        public var steps: [Double]                // one per day that has a count (phone or calibrated estimate)
        /// A VO₂ max worth reading against the reference: one the wearer entered, or the waist-based estimate.
        /// Never the waist-free estimate, which is mostly resting HR and would double-count it.
        public var cardioVO2: Double?
        public var zonesLowMin: Double?           // nil when the week had no heart-rate samples to read
        public var zonesHighMin: Double?
        public var strengthMin: Double
        public var leanMassPct: Double?
        public var gmi: Double?
        public init(chronoAge: Double, sex: String, restingHRs: [Double] = [], rmssds: [Double] = [],
                    sleepNights: [Double] = [], steps: [Double] = [], cardioVO2: Double? = nil,
                    zonesLowMin: Double? = nil, zonesHighMin: Double? = nil, strengthMin: Double = 0,
                    leanMassPct: Double? = nil, gmi: Double? = nil) {
            self.chronoAge = chronoAge; self.sex = sex; self.restingHRs = restingHRs; self.rmssds = rmssds
            self.sleepNights = sleepNights; self.steps = steps; self.cardioVO2 = cardioVO2
            self.zonesLowMin = zonesLowMin; self.zonesHighMin = zonesHighMin; self.strengthMin = strengthMin
            self.leanMassPct = leanMassPct; self.gmi = gmi
        }
    }

    public static func median(_ xs: [Double]) -> Double? {
        let s = xs.filter { $0.isFinite }.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The week's inputs: resting HR and HRV by MEDIAN (robust to one odd night), sleep and steps by MEAN,
    /// steps only from 3 days up, regularity from the nights' spread (≥3 nights), zone minutes only when the
    /// week had heart-rate samples, strength only when the week was worn (zones read) or strength was logged.
    public static func weeklyInputs(_ w: WeekData) -> Inputs {
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        let nights = w.sleepNights.filter { $0 > 0 }
        let hasZones = w.zonesLowMin != nil && w.zonesHighMin != nil
        return Inputs(
            chronoAge: w.chronoAge,
            restingHR: median(w.restingHRs),
            vo2max: w.cardioVO2,
            expectedVO2max: w.cardioVO2 == nil ? nil : expectedVO2max(age: w.chronoAge, sex: w.sex),
            sleepHours: mean(nights),
            sleepConsistency: sleepConsistency(nightlyHours: nights),
            rmssd: median(w.rmssds),
            rmssdNorm: rmssdNorm(forAge: w.chronoAge),
            steps: w.steps.count >= 3 ? mean(w.steps) : nil,
            gmi: w.gmi,
            zonesLowMin: hasZones ? w.zonesLowMin : nil,
            zonesHighMin: hasZones ? w.zonesHighMin : nil,
            strengthMin: hasZones || w.strengthMin > 0 ? w.strengthMin : nil,
            leanMassPct: w.leanMassPct,
            sex: w.sex)
    }

    /// Full Vitality + Body Age. Returns nil until at least `minFactors` inputs are present.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.chronoAge > 0 else { return nil }
        let contribs = contributions(inputs)
        guard contribs.count >= minFactors else { return nil }
        let sumLn = contribs.reduce(0) { $0 + $1.lnHazard } * overlapShrink
        let deltaAge = sumLn / lnHazardPerYear              // +ve = ages you
        let lo = max(minBodyAge, inputs.chronoAge - maxOffsetYears)
        let hi = min(maxBodyAge, inputs.chronoAge + maxOffsetYears)
        let bodyAge = clamp(inputs.chronoAge + deltaAge, min(lo, hi), max(lo, hi))
        let delta = inputs.chronoAge - bodyAge              // +ve = younger than your age
        let vitality = clamp(50 + delta * vitalityPerYear, 0, 100)
        return Result(vitality: vitality, bodyAge: bodyAge, chronoAge: inputs.chronoAge,
                      deltaYears: delta, bandYears: bandYears, contributions: contribs,
                      factorsUsed: contribs.count)
    }
}
