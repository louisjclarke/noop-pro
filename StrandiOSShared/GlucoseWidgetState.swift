import Foundation

/// NOOP Pro: the latest glucose value plus a short trace, handed from the app to the glucose widget
/// through the same App Group the other NOOP widgets use. Values are mg/dL; the widget formats them.
public struct GlucoseWidgetState: Codable, Equatable {
    public var mgdl: Double
    /// mg/dL per minute, when known.
    public var rate: Double?
    /// Measurement time.
    public var ts: Date
    public var mmol: Bool
    public var targetLow: Double
    public var targetHigh: Double
    /// Last 3 hours, oldest first, one value per reading.
    public var trace: [Double]
    /// Today's time in target, %.
    public var timeInTarget: Double?

    public init(mgdl: Double, rate: Double?, ts: Date, mmol: Bool, targetLow: Double, targetHigh: Double,
                trace: [Double], timeInTarget: Double?) {
        self.mgdl = mgdl; self.rate = rate; self.ts = ts; self.mmol = mmol
        self.targetLow = targetLow; self.targetHigh = targetHigh; self.trace = trace; self.timeInTarget = timeInTarget
    }

    public static let storageKey = "nooppro.glucose.widget"

    public static func load() -> GlucoseWidgetState? {
        guard let d = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = d.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(GlucoseWidgetState.self, from: data)
    }

    public func save() {
        guard let d = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        d.set(data, forKey: Self.storageKey)
    }

    public var valueText: String {
        mmol ? String(format: "%.1f", mgdl / 18.0182) : String(format: "%.0f", mgdl)
    }

    public var unitText: String { mmol ? "mmol/L" : "mg/dL" }

    public var arrow: String {
        guard let r = rate else { return "" }
        switch r {
        case ..<(-3.0): return "↓↓"
        case ..<(-2.0): return "↓"
        case ..<(-1.0): return "↘"
        case ..<1.0: return "→"
        case ..<2.0: return "↗"
        case ..<3.0: return "↑"
        default: return "↑↑"
        }
    }

    /// -1 low, 0 in target, 1 high.
    public var band: Int { mgdl < targetLow ? -1 : (mgdl > targetHigh ? 1 : 0) }
}
