import XCTest

@MainActor
final class PrinterActivityTests: XCTestCase {
    func testReadingAgeUsesOriginalTimeAndClampsFutureClockSkew() {
        let captured = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ReadingAgeLabel.age(captured, at: captured.addingTimeInterval(-5), clock: true), "0:00")
        XCTAssertEqual(ReadingAgeLabel.age(captured, at: captured.addingTimeInterval(65), clock: true), "1:05")
        XCTAssertEqual(ReadingAgeLabel.age(captured, at: captured.addingTimeInterval(3661), clock: true), "1:01:01")
        XCTAssertEqual(ReadingAgeLabel.age(captured, at: captured.addingTimeInterval(65), clock: false), "1 min ago")
        XCTAssertEqual(ReadingAgeLabel.age(captured, at: captured.addingTimeInterval(86400), clock: false), "1 day ago")
    }

    func testPrintingPromotesPrinterButIdlePollingDoesNotAndHistoryRestores() async throws {
        let first = PrinterProfile(name: "Workshop", kind: .bambu, address: "printer.invalid")
        let second = PrinterProfile(name: "Studio", kind: .moonraker, address: "http://studio.invalid")
        let now = Date(timeIntervalSince1970: 1000)
        var saved: [UUID: Date] = [first.id: now.addingTimeInterval(-100)]
        var deps = ProgressStoreDependencies(loadProfiles: { [first, second] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { profile in PrinterSnapshot(profile: profile, state: profile.id == second.id ? .printing : .idle, updatedAt: now) },
            reloadWidgets: {}, autoStart: false, verificationReports: false,
            loadActivity: { saved }, saveActivity: { saved = $0 })
        let store = ProgressStore(dependencies: deps)
        XCTAssertEqual(store.sortedProfiles.map(\.id), [first.id, second.id])
        await store.refresh()
        XCTAssertEqual(store.sortedProfiles.map(\.id), [second.id, first.id])
        XCTAssertEqual(saved[first.id], now.addingTimeInterval(-100))
        deps.fetch = { PrinterSnapshot(profile: $0, state: .idle, updatedAt: now.addingTimeInterval(100)) }
        let restored = ProgressStore(dependencies: deps)
        await restored.refresh()
        XCTAssertEqual(restored.sortedProfiles.map(\.id), [second.id, first.id])
        XCTAssertEqual(saved[second.id], now)
    }
    func testCaptureIntervalPersistsAndFailedSaveKeepsCurrentValue() {
        var saved: Double = 15
        var fail = false
        let deps = ProgressStoreDependencies(loadProfiles: { [] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false,
            verificationReports: false, loadCaptureInterval: { saved }, saveCaptureInterval: {
                if fail { throw PrinterControlError.rejected }; saved = $0
            })
        let store = ProgressStore(dependencies: deps)
        XCTAssertEqual(store.widgetCaptureInterval, 15)
        store.setCaptureInterval(3)
        XCTAssertEqual(ProgressStore(dependencies: deps).widgetCaptureInterval, 3)
        store.setCaptureInterval(30)
        XCTAssertEqual(ProgressStore(dependencies: deps).widgetCaptureInterval, 30)
        store.setCaptureInterval(0)
        XCTAssertEqual(saved, 30)
        fail = true
        store.setCaptureInterval(60)
        XCTAssertEqual(store.widgetCaptureInterval, 30)
        XCTAssertNotNil(store.errorMessage)
        saved = .nan
        XCTAssertEqual(ProgressStore(dependencies: deps).widgetCaptureInterval, 5)
    }
    func testCameraSetupRouteTargetsPrinterAndCannotOpenCompanion() throws {
        let id = UUID()
        let url = WidgetNavigation.cameraSetupURL(printerID: id)
        XCTAssertEqual(WidgetNavigation.cameraSetupPrinterID(from: url), id)
        XCTAssertNil(WidgetNavigation.printerID(from: url))
        XCTAssertNil(WidgetRefreshRequest.decode(url))
        XCTAssertNil(WidgetNavigation.cameraSetupPrinterID(from: URL(string: "https://camera-setup?id=\(id)")!))
        XCTAssertNil(WidgetNavigation.cameraSetupPrinterID(from: URL(string: "printprogress://camera-setup?id=invalid")!))
        XCTAssertNil(WidgetNavigation.cameraSetupPrinterID(from: URL(string: "printprogress://camera-setup?id=\(id)&id=\(UUID())")!))
    }
    func testWidgetCameraSetupDefaultsSnapshotsOnAndAppSetupPreservesTheSavedChoice() {
        var profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://printer.invalid")
        let widget = CameraSetupRequest(id: profile.id, fromWidget: true)
        let app = CameraSetupRequest(id: profile.id)
        XCTAssertTrue(widget.initialWidgetSnapshots(for: profile))
        XCTAssertFalse(app.initialWidgetSnapshots(for: profile))
        profile.camera = PrinterCameraSettings()
        profile.camera?.widgetSnapshotsEnabled = false
        XCTAssertTrue(widget.initialWidgetSnapshots(for: profile))
        XCTAssertFalse(app.initialWidgetSnapshots(for: profile))
        profile.camera?.widgetSnapshotsEnabled = true
        XCTAssertTrue(widget.initialWidgetSnapshots(for: profile))
        XCTAssertTrue(app.initialWidgetSnapshots(for: profile))
    }
    func testNavigationKeepsActionsSeparateAndHonorsPreference() throws {
        let id = UUID()
        XCTAssertEqual(WidgetNavigation.printerID(from: try XCTUnwrap(WidgetNavigation.url(printerID: id))), id)
        XCTAssertNil(WidgetNavigation.printerID(from: URL(string: "printprogress://stop?id=\(id)")!))
        XCTAssertNil(WidgetNavigation.printerID(from: URL(string: "other://open-printer?id=\(id)")!))
        XCTAssertNotNil(WidgetNavigation.companionURL(for: .bambu, destination: .companion))
        XCTAssertNil(WidgetNavigation.companionURL(for: .bambu, destination: .printProgress))
        XCTAssertNil(WidgetNavigation.companionURL(for: .moonraker, destination: .companion))
    }
}
