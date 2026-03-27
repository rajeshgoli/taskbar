import Foundation

struct AppRuntimeState: Equatable {
    var isLaunching: Bool = false
    var needsAttention: Bool = false
    var cpuPercent: Double?
    var memoryMB: Double?
    var progressFraction: Double?

    var activitySummary: String? {
        guard let cpuPercent, let memoryMB else {
            return nil
        }

        return "\(Int(cpuPercent.rounded()))% CPU  \(Int(memoryMB.rounded())) MB"
    }

    var normalizedProgressFraction: Double? {
        guard let progressFraction else {
            return nil
        }

        return min(max(progressFraction, 0), 1)
    }
}
