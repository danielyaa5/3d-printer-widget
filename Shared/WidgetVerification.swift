#if DEBUG
import Foundation

/// Local development evidence from the system's actual widget timeline provider.
/// This deliberately omits printer names, addresses, serial numbers, and filenames.
struct WidgetVerification: Codable {
    struct Reading: Codable {
        var kind: PrinterKind
        var status: String
        var offline: Bool
        var updatedAt: Date
        var nozzleTemperature: Double?
        var bedTemperature: Double?
        var chamberTemperature: Double?
        var chamberTarget: Double?
        var printerErrorCode: UInt32?
    }
    var generatedAt: Date
    var readings: [Reading]
    init(snapshots: [PrinterSnapshot]) {
        generatedAt = .now
        readings = snapshots.map { Reading(kind: $0.kind, status: $0.statusTitle, offline: $0.isOffline,
            updatedAt: $0.updatedAt, nozzleTemperature: $0.nozzleTemperature, bedTemperature: $0.bedTemperature,
            chamberTemperature: $0.chamberTemperature, chamberTarget: $0.chamberTarget,
            printerErrorCode: $0.printerErrorCode) }
    }
}

/// Counts and dates only; verifies that the actual widget can read the shared cache.
struct WidgetCameraVerification: Codable {
    var generatedAt: Date
    var family: String
    var timeline: Bool
    var sandboxContainerActive: Bool
    var statusCount: Int
    var allowedCount: Int
    var imageCount: Int
    var latestCapture: Date?
}
#endif
