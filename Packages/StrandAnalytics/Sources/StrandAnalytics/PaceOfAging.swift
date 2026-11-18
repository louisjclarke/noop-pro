import Foundation

/// Pace of aging: how many years Body Age moves for each calendar year.
///
/// Body Age = chronological age + offset, where the offset is what the habits add or take away. The
/// chronological part grows by exactly 1 a year, so the pace is `1 + slope of the offset`:
///   • 1.0×  the offset is steady: Body Age ages with the calendar
///   • below 1  the offset is falling: you are getting younger relative to the calendar
///   • below 0  Body Age itself is falling
///   • above 1  the offset is growing: Body Age is rising faster than the calendar
///
/// NOOP Pro fits the OFFSET, not the stored Body Age. Fitting Body Age directly would read a birthday
/// (a whole-year step in the age the week was scored at) as a sudden change in the wearer.
///
/// A weekly offset is noisy (a few bpm of resting heart rate is worth more than a year), so the estimate
/// (1) fits a straight line through up to 26 weekly readings, (2) measures the scatter around it, and
/// (3) shrinks the slope towards 1.0× in proportion to that scatter (a normal prior on the true trend), so
/// a short or jumpy history reads close to 1.0× and only a long, consistent trend moves it far. A slope past
/// ±3 years/year is a step in the inputs, not physiology, and is capped first. Clamped to the −1…3× dial.
/// Approach adapted from PHMN (aansun/PHMNoop, PolyForm Noncommercial), re-based on the offset.
public enum PaceOfAging {

    public struct Reading: Sendable, Equatable {
        /// Seconds since 1970 of the weekly reading.
        public let time: TimeInterval
        /// Body Age minus chronological age for that week, years (+ = older than your age).
        public let offset: Double
        public init(time: TimeInterval, offset: Double) { self.time = time; self.offset = offset }
    }

    public enum Confidence: String, Sendable { case early, building, solid }

    public struct Result: Sendable, Equatable {
        /// Dial value, −1.0 … 3.0.
        public let pace: Double
        /// Raw fitted slope of the offset, years per year, before shrinking.
        public let slopeYearsPerYear: Double
        /// How much of the raw trend is kept (0…1). Low = mostly the neutral 1.0×.
        public let weight: Double
        public let weeks: Int
        public let confidence: Confidence
        public enum Band: Sendable { case slower, normal, faster }
        /// Words for the dial, with a 0.15 dead band around 1.0×.
        public var band: Band { pace < 0.85 ? .slower : (pace > 1.15 ? .faster : .normal) }
    }

    public static let range: ClosedRange<Double> = -1...3
    public static let windowDays = 182
    public static let minReadings = 6
    public static let minSpanDays = 35.0
    /// Prior spread of the real trend, years of offset per year. Larger trusts the data more.
    static let priorSD = 1.0
    /// Floor on the residual scatter (years): a weekly reading is never exact.
    static let noiseFloor = 0.6
    static let slopeCap = 3.0
    static let secondsPerYear = 365.25 * 86_400

    /// The pace, or nil without enough history (fewer than 6 weekly readings spanning 5 weeks).
    public static func compute(_ readings: [Reading]) -> Result? {
        let sorted = readings.filter { $0.offset.isFinite && $0.time.isFinite }.sorted { $0.time < $1.time }
        guard let last = sorted.last else { return nil }
        let cutoff = last.time - Double(windowDays) * 86_400
        let r = sorted.filter { $0.time >= cutoff }
        guard r.count >= minReadings, let first = r.first,
              (last.time - first.time) / 86_400 >= minSpanDays else { return nil }
        let n = Double(r.count)
        let xs = r.map { $0.time / secondsPerYear }
        let ys = r.map(\.offset)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let slope = sxy / sxx
        let intercept = my - slope * mx
        let sse = zip(xs, ys).reduce(0) { $0 + pow($1.1 - (intercept + slope * $1.0), 2) }
        let sigma = max((sse / max(n - 2, 1)).squareRoot(), noiseFloor)
        let se = sigma / sxx.squareRoot()
        let w = priorSD * priorSD / (priorSD * priorSD + se * se)
        let capped = min(max(slope, -slopeCap), slopeCap)
        let pace = min(max(1 + w * capped, range.lowerBound), range.upperBound)
        let conf: Confidence = w >= 0.5 ? .solid : (w >= 0.2 ? .building : .early)
        return Result(pace: pace, slopeYearsPerYear: slope, weight: w, weeks: r.count, confidence: conf)
    }
}
