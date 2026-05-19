import Foundation

enum SystemResourceMetric: CaseIterable {
    case memory
    case cpu
    case gpu
}

enum MemoryPressureLevel: String, Equatable {
    case normal
    case warning
    case critical
    case unknown

    var displayName: String {
        switch self {
        case .normal:
            return "Normal"
        case .warning:
            return "Warning"
        case .critical:
            return "Critical"
        case .unknown:
            return "Unknown"
        }
    }
}

struct SystemResourceSnapshot: Equatable {
    var memoryPressureLevel: MemoryPressureLevel
    var memoryPressurePercent: Double?
    var memoryFreePercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var cpuPercent: Double?
    var gpuPercent: Double?

    static let empty = SystemResourceSnapshot(
        memoryPressureLevel: .unknown,
        memoryPressurePercent: nil,
        memoryFreePercent: nil,
        memoryUsedBytes: nil,
        memoryTotalBytes: nil,
        cpuPercent: nil,
        gpuPercent: nil
    )

    var memoryUsedPercent: Double? {
        guard let memoryUsedBytes, let memoryTotalBytes, memoryTotalBytes > 0 else {
            return memoryPressurePercent
        }

        return min(max((Double(memoryUsedBytes) / Double(memoryTotalBytes)) * 100, 0), 100)
    }
}
