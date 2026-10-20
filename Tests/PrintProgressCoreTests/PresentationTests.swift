import XCTest
@testable import PrintProgressCore

final class PresentationTests: XCTestCase {
    private let profile = PrinterProfile(name: "Workshop", kind: .moonraker, address: "http://printer.local:7125")

    func testWidgetHostFailureDoesNotTurnFreshOnlinePrinterOffline() {
        let now = Date()
        let reading = PrinterSnapshot(profile: profile, state: .finished, progress: 1, updatedAt: now.addingTimeInterval(-47))
        let result = WidgetSnapshotPolicy.refreshFailed(profile: profile, cached: reading, at: now)
        XCTAssertEqual(result, reading)
        XCTAssertFalse(result.isOffline)
        XCTAssertEqual(result.statusTitle, "Finished")
        XCTAssertTrue(WidgetSnapshotPolicy.canUseCache(reading, at: now))
    }
    func testWidgetWithoutFreshReadingAsksForRefreshAndPreservesTimestamp() {
        let now = Date()
        let original = PrinterSnapshot(profile: profile, state: .printing, progress: 0.5,
            remainingSeconds: 600, updatedAt: now.addingTimeInterval(-300))
        let result = WidgetSnapshotPolicy.refreshFailed(profile: profile, cached: original, at: now)
        XCTAssertFalse(result.isOffline)
        XCTAssertEqual(result.statusTitle, "Refresh needed")
        XCTAssertEqual(result.updatedAt, original.updatedAt)
        XCTAssertEqual(result.progress, original.progress)
        XCTAssertNil(result.finishDate)
    }
    func testWidgetKeepsOfflineEvidenceReportedByTheApp() {
        let now = Date()
        let reading = PrinterSnapshot(profile: profile, state: .printing, progress: 0.5, updatedAt: now, isOffline: true)
        XCTAssertEqual(WidgetSnapshotPolicy.refreshFailed(profile: profile, cached: reading, at: now).statusTitle, "Offline")
    }
    func testWidgetWithoutAnyReadingDoesNotInventAnOfflinePrinter() {
        let result = WidgetSnapshotPolicy.refreshFailed(profile: profile, cached: nil)
        XCTAssertFalse(result.isOffline)
        XCTAssertEqual(result.statusTitle, "Refresh needed")
        XCTAssertEqual(result.updatedAt, .distantPast)
        XCTAssertNil(result.progress)
    }
    func testMenuBarUsesActivePrinterAndHonorsExplicitChoice() {
        var secondProfile = profile; secondProfile.id = UUID(); secondProfile.name = "Studio"
        let idle = PrinterSnapshot(profile: profile, state: .idle)
        let printing = PrinterSnapshot(profile: secondProfile, state: .printing, progress: 0.64, remainingSeconds: 5400)
        XCTAssertEqual(MenuBarPresentation.select([idle, printing])?.id, secondProfile.id)
        XCTAssertEqual(MenuBarPresentation.select([idle, printing], preferredID: profile.id.uuidString)?.id, profile.id)
        XCTAssertEqual(MenuBarPresentation.text(printing, mode: .percentage), "64%")
        XCTAssertEqual(MenuBarPresentation.text(printing, mode: .timeRemaining), "1h 30m")
    }
    func testMenuBarPausedAndFinishedDoNotPretendTimeIsCountingDown() {
        let paused = PrinterSnapshot(profile: profile, state: .paused, progress: 0.4, remainingSeconds: 5400)
        XCTAssertEqual(MenuBarPresentation.text(paused, mode: .timeRemaining), "Paused")
        let done = PrinterSnapshot(profile: profile, state: .finished, progress: 1)
        XCTAssertEqual(MenuBarPresentation.text(done, mode: .timeRemaining), "Done")
        XCTAssertEqual(MenuBarPresentation.text(done.offline(PrinterError.timeout), mode: .percentage), "Offline")
    }
    func testMenuBarTimeLabelsStayCompact() {
        XCTAssertEqual(MenuBarPresentation.compactDuration(0), "<1m")
        XCTAssertEqual(MenuBarPresentation.compactDuration(540), "9m")
        XCTAssertEqual(MenuBarPresentation.compactDuration(7200), "2h")
        XCTAssertEqual(MenuBarPresentation.compactDuration(.infinity), "—")
    }
    func testOldSnapshotsDecodeWithoutNewChamberAndRefreshFields() throws {
        let original = PrinterSnapshot(profile: profile, state: .idle)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["chamberTemperature", "chamberTarget", "refreshUnavailable"] { json.removeValue(forKey: key) }
        let result = try JSONDecoder().decode(PrinterSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(result.id, original.id)
        XCTAssertNil(result.chamberTemperature)
        XCTAssertNil(result.refreshUnavailable)
    }
}
