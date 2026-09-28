import Foundation

/// Active time of a report split into the three attention bands.
public struct BandTotals: Equatable, Sendable {
    public var focused: TimeInterval
    public var mild: TimeInterval
    public var brainSplit: TimeInterval

    public var active: TimeInterval { focused + mild + brainSplit }

    public static func of(_ slices: [ConcurrencySlice], threshold: Int) -> BandTotals {
        let threshold = BrainSplitRules.clamp(threshold)
        var totals = BandTotals(focused: 0, mild: 0, brainSplit: 0)
        for slice in slices where slice.concurrency > 0 {
            if slice.concurrency >= threshold {
                totals.brainSplit += slice.duration
            } else if slice.concurrency >= 2 {
                totals.mild += slice.duration
            } else {
                totals.focused += slice.duration
            }
        }
        return totals
    }
}

public enum FocusTier: String, Equatable, Sendable {
    case flow
    case steady
    case scattered
    case overloaded

    public var title: String {
        switch self {
        case .flow: "心流"
        case .steady: "稳定"
        case .scattered: "分散"
        case .overloaded: "过载"
        }
    }

    public var tagline: String {
        switch self {
        case .flow: "一次一件，脑子很清爽"
        case .steady: "偶有并行，整体可控"
        case .scattered: "线程有点多，注意力在漏"
        case .overloaded: "上下文切换吃掉了大半时间"
        }
    }
}

/// One number for "how single-threaded was this stretch": solo time counts
/// fully, parallel time partially, brain-split time barely, and frequent
/// context switches cost a little on top.
public enum FocusScore {
    static let mildWeight = 0.55
    static let splitWeight = 0.15
    static let penaltyPerSwitchPerHour = 0.03
    static let maxSwitchPenalty = 0.15

    public static func score(report: ParallelismReport) -> Int? {
        let bands = BandTotals.of(report.slices, threshold: report.threshold)
        guard bands.active > 0 else { return nil }
        let weighted = (bands.focused + bands.mild * mildWeight + bands.brainSplit * splitWeight) / bands.active
        let hours = max(bands.active / 3600, 0.5)
        let penalty = min(maxSwitchPenalty, Double(report.switchCount) / hours * penaltyPerSwitchPerHour)
        return Int((max(0, weighted - penalty) * 100).rounded())
    }

    public static func tier(for score: Int) -> FocusTier {
        switch score {
        case 85...: .flow
        case 65..<85: .steady
        case 40..<65: .scattered
        default: .overloaded
        }
    }
}
