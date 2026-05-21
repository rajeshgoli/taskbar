import Combine
import Darwin
import Foundation
import IOKit

@MainActor
final class SystemResourceMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemResourceSnapshot = .empty

    private let sampleInterval: TimeInterval
    private var timer: Timer?
    private var previousCPUTicks: ProcessorTicks?

    init(sampleInterval: TimeInterval = 2.0) {
        self.sampleInterval = sampleInterval
        refresh()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        let memory = sampleMemoryPressure()
        snapshot = SystemResourceSnapshot(
            memoryPressureLevel: memory.level,
            memoryPressurePercent: memory.pressurePercent,
            memoryFreePercent: memory.freePercent,
            memoryUsedBytes: memory.usedBytes,
            memoryTotalBytes: memory.totalBytes,
            cpuPercent: sampleCPUPercent(),
            gpuPercent: sampleGPUPercent()
        )
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func sampleMemoryPressure() -> MemoryPressureSample {
        let rawPressureLevel = sysctlInt32(named: "kern.memorystatus_vm_pressure_level")
        let freePercent = sysctlInt32(named: "kern.memorystatus_level").map { value in
            min(max(Double(value), 0), 100)
        }
        let totalBytes = physicalMemoryBytes()
        let usedBytes = sampleUsedMemoryBytes(totalBytes: totalBytes, freePercent: freePercent)

        let level: MemoryPressureLevel
        switch rawPressureLevel {
        case 1:
            level = .normal
        case 2:
            level = .warning
        case 3, 4:
            level = .critical
        default:
            level = .unknown
        }

        return MemoryPressureSample(
            level: level,
            pressurePercent: freePercent.map { 100 - $0 },
            freePercent: freePercent,
            usedBytes: usedBytes,
            totalBytes: totalBytes
        )
    }

    private func physicalMemoryBytes() -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else {
            return nil
        }

        return value
    }

    private func sampleUsedMemoryBytes(totalBytes: UInt64?, freePercent: Double?) -> UInt64? {
        let pageSize = UInt64(vm_kernel_page_size)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    reboundPointer,
                    &count
                )
            }
        }

        if result == KERN_SUCCESS {
            return Self.activityMonitorUsedMemoryBytes(
                stats: stats,
                pageSize: pageSize,
                totalBytes: totalBytes
            )
        }

        guard let totalBytes, let freePercent else {
            return nil
        }

        return UInt64(Double(totalBytes) * ((100 - freePercent) / 100))
    }

    private func sampleCPUPercent() -> Double? {
        guard let currentTicks = readProcessorTicks() else {
            return nil
        }

        defer {
            previousCPUTicks = currentTicks
        }

        guard let previousCPUTicks else {
            return nil
        }

        let idleDelta = currentTicks.idle.saturatingSubtract(previousCPUTicks.idle)
        let totalDelta = currentTicks.total.saturatingSubtract(previousCPUTicks.total)
        guard totalDelta > 0 else {
            return nil
        }

        let activeDelta = totalDelta.saturatingSubtract(idleDelta)
        return min(max((Double(activeDelta) / Double(totalDelta)) * 100, 0), 100)
    }

    private func readProcessorTicks() -> ProcessorTicks? {
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else {
            return nil
        }

        defer {
            let byteCount = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                byteCount
            )
        }

        let cpuStateCount = Int(CPU_STATE_MAX)
        var ticks = ProcessorTicks()

        for cpuIndex in 0 ..< Int(processorCount) {
            let baseIndex = cpuIndex * cpuStateCount
            ticks.user += UInt64(processorInfo[baseIndex + Int(CPU_STATE_USER)])
            ticks.nice += UInt64(processorInfo[baseIndex + Int(CPU_STATE_NICE)])
            ticks.system += UInt64(processorInfo[baseIndex + Int(CPU_STATE_SYSTEM)])
            ticks.idle += UInt64(processorInfo[baseIndex + Int(CPU_STATE_IDLE)])
        }

        return ticks
    }

    private func sampleGPUPercent() -> Double? {
        guard let matchingDictionary = IOServiceMatching("IOAccelerator") else {
            return nil
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer {
            IOObjectRelease(iterator)
        }

        var samples: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer {
                IOObjectRelease(service)
            }

            guard
                let property = IORegistryEntryCreateCFProperty(
                    service,
                    "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue(),
                let statistics = property as? [String: Any]
            else {
                continue
            }

            if let utilization = doubleValue(statistics["Device Utilization %"]) {
                samples.append(utilization)
            } else {
                let renderer = doubleValue(statistics["Renderer Utilization %"])
                let tiler = doubleValue(statistics["Tiler Utilization %"])
                if let utilization = [renderer, tiler].compactMap({ $0 }).max() {
                    samples.append(utilization)
                }
            }
        }

        return samples.max().map { min(max($0, 0), 100) }
    }

    private func sysctlInt32(named name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }

        return value
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int32:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    nonisolated static func activityMonitorUsedMemoryBytes(
        stats: vm_statistics64,
        pageSize: UInt64,
        totalBytes: UInt64?
    ) -> UInt64 {
        // Match Activity Monitor's "Memory Used": app/internal memory + wired + compressed,
        // excluding file-backed cache that macOS can reclaim.
        let usedPages =
            UInt64(stats.internal_page_count) +
            UInt64(stats.wire_count) +
            UInt64(stats.compressor_page_count)
        let usedBytes = usedPages * pageSize

        guard let totalBytes else {
            return usedBytes
        }

        return min(usedBytes, totalBytes)
    }
}

private struct MemoryPressureSample {
    let level: MemoryPressureLevel
    let pressurePercent: Double?
    let freePercent: Double?
    let usedBytes: UInt64?
    let totalBytes: UInt64?
}

private struct ProcessorTicks {
    var user: UInt64 = 0
    var nice: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0

    var total: UInt64 {
        user + nice + system + idle
    }
}

private extension UInt64 {
    func saturatingSubtract(_ rhs: UInt64) -> UInt64 {
        self >= rhs ? self - rhs : 0
    }
}
