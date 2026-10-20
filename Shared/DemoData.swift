import Foundation

/// Fictional readings used by the interactive demo and public screenshots.
/// These profiles are never saved to Keychain or used for network requests.
enum DemoData {
    static let profiles = [
        PrinterProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                       name: "Workshop", kind: .bambu, address: "workshop.example"),
        PrinterProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                       name: "Studio", kind: .moonraker, address: "http://studio.example:7125")
    ]

    static func snapshots(state: PrintState = .printing, date: Date = .now) -> [PrinterSnapshot] {
        [
            PrinterSnapshot(profile: profiles[0], state: state,
                progress: state == .finished ? 1 : 0.64, jobName: "Desk planter",
                remainingSeconds: state == .finished ? nil : 2520,
                currentLayer: state == .finished ? 200 : 128, totalLayers: 200,
                nozzleTemperature: 220, bedTemperature: 60, chamberTemperature: 42, chamberTarget: 45,
                updatedAt: date),
            PrinterSnapshot(profile: profiles[1], state: .printing, progress: 0.28,
                jobName: "Cable organizer", remainingSeconds: 5640, currentLayer: 56, totalLayers: 200,
                nozzleTemperature: 215, bedTemperature: 60, chamberTemperature: 28,
                updatedAt: date)
        ]
    }
}
