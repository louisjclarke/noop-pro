import XCTest
@testable import StrandAnalytics

final class VitalityEngineTests: XCTestCase {

    /// An average-for-their-age person nets ~0 hazard → Body Age == chronological age, Vitality 50.
    func testAveragePersonReadsAtTheirAge() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 60, vo2max: 45, expectedVO2max: 45,
            sleepHours: 7.5, sleepConsistency: 0.75, rmssd: 45, rmssdNorm: 45, steps: 7000))!
        XCTAssertEqual(r.bodyAge, 40, accuracy: 0.01)
        XCTAssertEqual(r.vitality, 50, accuracy: 0.01)
        XCTAssertEqual(r.deltaYears, 0, accuracy: 0.01)
        XCTAssertEqual(r.factorsUsed, 6)
    }

    /// A clearly healthy person reads younger + higher vitality (hand-computed Δage ≈ −7.15; resting HR
    /// neutral at 60 bpm, the sleep-measured reference).
    func testHealthyPersonIsYounger() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 52, vo2max: 55.5, expectedVO2max: 45,
            sleepHours: 7.5, sleepConsistency: 0.9, rmssd: 54, rmssdNorm: 45, steps: 11000))!
        XCTAssertEqual(r.bodyAge, 32.85, accuracy: 0.1)
        XCTAssertEqual(r.vitality, 67.86, accuracy: 0.2)
        XCTAssertGreaterThan(r.deltaYears, 0)   // younger than chrono age
    }

    /// A clearly unhealthy person reads older + lower vitality (hand-computed Δage ≈ +10.14).
    func testUnhealthyPersonIsOlder() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 80, vo2max: 34.5, expectedVO2max: 45,
            sleepHours: 5.5, sleepConsistency: 0.5, rmssd: 31.5, rmssdNorm: 45, steps: 3000))!
        XCTAssertEqual(r.bodyAge, 50.14, accuracy: 0.1)
        XCTAssertEqual(r.vitality, 24.65, accuracy: 0.2)
        XCTAssertLessThan(r.deltaYears, 0)      // older than chrono age
    }

    /// Below the minimum-factor honesty gate → nil (don't show a number on too little data).
    func testNilBelowMinFactors() {
        XCTAssertNil(VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5))) // 2 factors
        XCTAssertNotNil(VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5,
                                                     sleepConsistency: 0.75)))                     // 3 factors
    }

    /// Body Age + Vitality stay within their clamped ranges at the extremes.
    func testClamps() {
        let young = VitalityEngine.compute(.init(
            chronoAge: 22, restingHR: 40, vo2max: 70, expectedVO2max: 40,
            sleepHours: 7.5, sleepConsistency: 1.0, rmssd: 90, rmssdNorm: 45, steps: 11000))!
        XCTAssertGreaterThanOrEqual(young.bodyAge, VitalityEngine.minBodyAge)
        XCTAssertLessThanOrEqual(young.vitality, 100)
        XCTAssertGreaterThanOrEqual(young.vitality, 0)

        let old = VitalityEngine.compute(.init(
            chronoAge: 85, restingHR: 110, vo2max: 12, expectedVO2max: 35,
            sleepHours: 3, sleepConsistency: 0.1, rmssd: 8, rmssdNorm: 30, steps: 200))!
        XCTAssertLessThanOrEqual(old.bodyAge, VitalityEngine.maxBodyAge)
        XCTAssertGreaterThanOrEqual(old.vitality, 0)
    }

    func testRmssdNormByAge() {
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 20), 47, accuracy: 0.01)
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 40), 33, accuracy: 0.01)
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 45), 31, accuracy: 0.01)   // halfway 33→29
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 90), 20, accuracy: 0.01)   // clamps to last anchor
    }

    func testSleepConsistency() {
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: [7, 7, 7, 7])!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: [6, 8, 6, 8])!, 0.857, accuracy: 0.005)
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [7, 7]))   // < 3 nights
    }

    /// Contributions carry the right sign: a low resting HR is protective (negative), a high one ages you.
    func testContributionSigns() {
        let lowRHR = VitalityEngine.contributions(.init(chronoAge: 40, restingHR: 50))
            .first { $0.key == "rhr" }!
        XCTAssertLessThan(lowRHR.lnHazard, 0)
        let highRHR = VitalityEngine.contributions(.init(chronoAge: 40, restingHR: 85))
            .first { $0.key == "rhr" }!
        XCTAssertGreaterThan(highRHR.lnHazard, 0)
    }

    // NOOP Pro: glucose control factor.
    func testGlucoseFactorOnlyAgesAboveThreshold() {
        let base = VitalityEngine.Inputs(chronoAge: 30, restingHR: 60, sleepHours: 7.5, steps: 8000)
        var normal = base; normal.gmi = 5.4
        var high = base; high.gmi = 6.7
        let c0 = VitalityEngine.contributions(normal).first { $0.key == "glucose" }
        let c1 = VitalityEngine.contributions(high).first { $0.key == "glucose" }
        XCTAssertEqual(c0?.lnHazard ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(c1?.lnHazard ?? 0, 0.30, accuracy: 1e-9)
        XCTAssertNil(VitalityEngine.contributions(base).first { $0.key == "glucose" })
        let r0 = VitalityEngine.compute(normal)!, r1 = VitalityEngine.compute(high)!
        XCTAssertGreaterThan(r1.bodyAge, r0.bodyAge)
    }

    // MARK: NOOP Pro Body Age v2

    /// The old absolute floor of 20 made every under-20 read older than they were. A healthy 18-year-old
    /// must be able to read younger than 18.
    func testUnderTwentyCanReadYounger() {
        let r = VitalityEngine.compute(.init(chronoAge: 18, restingHR: 48, sleepHours: 8,
                                             sleepConsistency: 0.9, steps: 9000))!
        XCTAssertEqual(r.bodyAge, 15.27, accuracy: 0.05)
        XCTAssertGreaterThan(r.deltaYears, 0)
    }

    /// Body Age stays within ±maxOffsetYears of the real age.
    func testRelativeClamp() {
        let r = VitalityEngine.compute(.init(chronoAge: 30, restingHR: 140, sleepHours: 2,
                                             sleepConsistency: 0, rmssd: 5, rmssdNorm: 40, steps: 0, gmi: 9,
                                             zonesLowMin: 0, zonesHighMin: 0, strengthMin: 0))!
        XCTAssertEqual(r.bodyAge, 30 + VitalityEngine.maxOffsetYears, accuracy: 1e-9)
    }

    /// Someone exactly at every break-even nets zero on all eleven-factor inputs that are present.
    func testBreakEvensAreNeutral() {
        let i = VitalityEngine.Inputs(chronoAge: 30, restingHR: 60, sleepHours: 7.5, sleepConsistency: 0.75,
                                      zonesLowMin: 92, zonesHighMin: 10, strengthMin: 45,
                                      leanMassPct: 80, sex: "male")
        for c in VitalityEngine.contributions(i) {
            XCTAssertEqual(c.lnHazard, 0, accuracy: 1e-12, c.key)
        }
        XCTAssertEqual(VitalityEngine.compute(i)!.bodyAge, 30, accuracy: 1e-9)
    }

    /// More training reads younger, and each activity curve flattens where the studies do.
    func testActivityFactors() {
        let i = VitalityEngine.Inputs(chronoAge: 30, restingHR: 60, sleepHours: 7.5, sleepConsistency: 0.75,
                                      zonesLowMin: 300, zonesHighMin: 60, strengthMin: 90)
        XCTAssertEqual(VitalityEngine.compute(i)!.bodyAge, 28.44, accuracy: 0.05)
        XCTAssertEqual(VitalityEngine.strengthEffect(60), VitalityEngine.strengthEffect(300), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.highZoneEffect(120), VitalityEngine.highZoneEffect(400), accuracy: 1e-12)
        XCTAssertLessThan(VitalityEngine.lowZoneEffect(200), VitalityEngine.lowZoneEffect(92))
    }

    /// Lean mass: neutral up to the sex-specific body-fat cut-off, never protective, capped.
    func testLeanMassIsSexAwareAndCapped() {
        XCTAssertEqual(VitalityEngine.leanMassEffect(leanPct: 75, sex: "male"), 0, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.leanMassEffect(leanPct: 70, sex: "male"), 0.10, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.leanMassEffect(leanPct: 70, sex: "female"), 0, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.leanMassEffect(leanPct: 95, sex: "male"), 0, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.leanMassEffect(leanPct: 30, sex: "male"), 0.30, accuracy: 1e-12)
    }

    /// The per-factor years add up exactly to the offset when nothing is clamped.
    func testYearsSumToBodyAge() {
        let i = VitalityEngine.Inputs(chronoAge: 35, restingHR: 55, sleepHours: 6.5, sleepConsistency: 0.8,
                                      rmssd: 40, rmssdNorm: VitalityEngine.rmssdNorm(forAge: 35), steps: 9000,
                                      gmi: 5.9, zonesLowMin: 150, zonesHighMin: 20, strengthMin: 30)
        let r = VitalityEngine.compute(i)!
        let sum = r.contributions.reduce(0) { $0 + VitalityEngine.years(of: $1) }
        XCTAssertEqual(r.bodyAge, 35 + sum, accuracy: 1e-9)
    }

    func testExpectedVO2max() {
        XCTAssertEqual(VitalityEngine.expectedVO2max(age: 25, sex: "male"), 48.0, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.expectedVO2max(age: 75, sex: "female"), 18.3, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.expectedVO2max(age: 18, sex: "male"),
                       VitalityEngine.expectedVO2max(age: 20, sex: "male"), accuracy: 1e-9)
    }

    /// The weekly reader: medians for RHR/HRV, steps need 3 days, zones need samples, strength needs a worn week.
    func testWeeklyInputs() {
        var w = VitalityEngine.WeekData(chronoAge: 18, sex: "male", restingHRs: [50, 52, 90], rmssds: [80, 90, 10],
                                        sleepNights: [8, 7, 9], steps: [8000, 9000])
        var i = VitalityEngine.weeklyInputs(w)
        XCTAssertEqual(i.restingHR, 52)
        XCTAssertEqual(i.rmssd, 80)
        XCTAssertEqual(i.sleepHours ?? 0, 8, accuracy: 1e-9)
        XCTAssertNil(i.steps)
        XCTAssertNil(i.zonesLowMin)
        XCTAssertNil(i.strengthMin)
        XCTAssertNil(i.expectedVO2max)
        w.steps.append(10000); w.zonesLowMin = 200; w.zonesHighMin = 30; w.cardioVO2 = 55
        i = VitalityEngine.weeklyInputs(w)
        XCTAssertEqual(i.steps ?? 0, 9000, accuracy: 1e-9)
        XCTAssertEqual(i.strengthMin, 0)
        XCTAssertEqual(i.expectedVO2max ?? 0, 50.36, accuracy: 1e-9)   // age 18 reads the age-20 reference
    }
}

final class PaceOfAgingTests: XCTestCase {
    private func readings(_ offsets: [Double]) -> [PaceOfAging.Reading] {
        offsets.enumerated().map { PaceOfAging.Reading(time: Double($0.offset) * 7 * 86_400, offset: $0.element) }
    }

    func testNeedsSixReadingsOverFiveWeeks() {
        XCTAssertNil(PaceOfAging.compute(readings([0, 0, 0, 0, 0])))
        XCTAssertNotNil(PaceOfAging.compute(readings([0, 0, 0, 0, 0, 0])))
    }

    func testSteadyOffsetIsOneX() {
        let r = PaceOfAging.compute(readings(Array(repeating: -2, count: 20)))!
        XCTAssertEqual(r.pace, 1, accuracy: 1e-9)
        XCTAssertEqual(r.band, .normal)
    }

    /// A falling offset over half a year reads slower than the calendar, shrunk towards 1.0×.
    func testFallingOffsetReadsSlower() {
        let offsets = (0..<26).map { -Double($0) * 0.08 }        // −2 years of offset over 25 weeks
        let r = PaceOfAging.compute(readings(offsets))!
        XCTAssertLessThan(r.pace, 0.85)
        XCTAssertGreaterThanOrEqual(r.pace, PaceOfAging.range.lowerBound)
        XCTAssertEqual(r.band, .slower)
    }

    /// Noisy short history stays near 1.0×.
    func testNoiseShrinksTowardsOne() {
        let r = PaceOfAging.compute(readings([0, 2, -2, 2, -2, 1]))!
        XCTAssertEqual(r.pace, 1, accuracy: 0.6)
        XCTAssertEqual(r.confidence, .early)
    }
}
