import XCTest
import WidgetKit

final class PrinterSelectionTests: XCTestCase {
    func testAutomaticCanBeResolvedWithoutSavedPrinterAccess() async throws {
        let result = try await PrinterEntityQuery().entities(for: [PrinterEntity.automatic.id])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Automatic")
        XCTAssertNil(result.first?.selectedPrinterID)
    }

    func testReturningToAutomaticRestoresTheFleetAndActivePrinterPriority() {
        let idleProfile = PrinterProfile(name: "Studio", kind: .moonraker, address: "http://studio.invalid")
        let activeProfile = PrinterProfile(name: "Workshop", kind: .bambu, address: "printer.invalid")
        let idle = PrinterSnapshot(profile: idleProfile, state: .idle)
        let active = PrinterSnapshot(profile: activeProfile, state: .printing, progress: 0.5)
        let selected = PrinterEntity(id: idle.id.uuidString, name: idle.name)
        var entry = ProgressEntry(date: .now, snapshots: [idle, active], selectedID: selected.selectedPrinterID)
        XCTAssertEqual(entry.displayed.map(\.id), [idle.id])
        entry.selectedID = PrinterEntity.automatic.selectedPrinterID
        XCTAssertEqual(entry.displayed.map(\.id), [active.id, idle.id])
    }
}
