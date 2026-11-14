#if os(iOS)
import Foundation
import StrandGlucose

/// Narrow entry points that shared (macOS + iOS) NOOP code calls behind `#if os(iOS)`, so the glucose
/// layer can feed core engines without those files importing anything iOS-only.
enum NoopProGlucoseBridge {
    /// 14-day Glucose Management Indicator (%), or nil unless at least 10 of the last 14 days are at
    /// least half covered by readings — the consensus wants ~14 days / 70% before GMI is meaningful.
    static func gmi14(now: Date = Date()) -> Double? {
        let t = Int(now.timeIntervalSince1970)
        let series = GlucoseStore.shared.series(from: t - 14 * 86_400, to: t + 600)
        let covered = GlucoseFusion.dailySummaries(series).count
        guard covered >= 10, let s = GlucoseMetrics.summary(series, windowSeconds: 14 * 86_400) else { return nil }
        return s.gmi
    }
}
#endif
