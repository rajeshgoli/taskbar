import Darwin
import Testing
@testable import DeskBar

@Test
func activityMonitorMemoryUsedExcludesFileBackedCache() {
    var stats = vm_statistics64()
    stats.internal_page_count = 100
    stats.external_page_count = 50
    stats.wire_count = 20
    stats.compressor_page_count = 30

    let usedBytes = SystemResourceMonitor.activityMonitorUsedMemoryBytes(
        stats: stats,
        pageSize: 4,
        totalBytes: nil
    )

    #expect(usedBytes == 600)
}
