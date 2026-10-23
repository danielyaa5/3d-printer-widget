import XCTest

@MainActor
final class PrinterActivityTests: XCTestCase {
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
