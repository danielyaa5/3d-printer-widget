import XCTest
import AppKit
import SwiftUI
import WidgetKit

/// Unshown native windows render the production views. This supplements the
/// installed-app interaction tests; it is not a substitute for them.
@MainActor
final class NativeLayoutTests: XCTestCase {
    private let fixture = PrinterProfile(name: "Workshop", kind: .bambu, address: "printer.local")
    private var output: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/UIRegression.noindex")
    }
    private func store(_ readings: [PrinterSnapshot]) -> ProgressStore {
        let profiles = readings.map { PrinterProfile(id: $0.id, name: $0.name, kind: $0.kind, address: "http://printer.local") }
        return ProgressStore(dependencies: .init(loadProfiles: { profiles },
            loadSnapshot: { id in readings.first { $0.id == id } }, saveProfiles: { _ in },
            saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { profile in readings.first { $0.id == profile.id } ?? PrinterSnapshot(profile: profile) }, reloadWidgets: {},
            autoStart: false, verificationReports: false))
    }
    private var reading: PrinterSnapshot {
        PrinterSnapshot(profile: fixture, state: .paused, progress: 0.45,
            jobName: "A deliberately long planter filename to check line wrapping",
            remainingSeconds: 3780, currentLayer: 45, totalLayers: 100,
            nozzleTemperature: 220, bedTemperature: 100, chamberTemperature: 59, chamberTarget: 60)
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool = false) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light))
        let bounds = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = bounds
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000, "\(name) unexpectedly empty")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    func testSmallMediumLargeWidgetsAndMissingTemperaturesInBothAppearances() throws {
        var second = reading; second.id = UUID(); second.name = "Studio"; second.state = .idle; second.progress = nil
        var missing = reading; missing.nozzleTemperature = nil; missing.bedTemperature = nil; missing.chamberTemperature = nil
        for dark in [false, true] {
            for (family, size, title) in [(WidgetFamily.systemSmall, NSSize(width: 158, height: 158), "small"),
                                        (.systemMedium, NSSize(width: 360, height: 170), "medium"),
                                        (.systemLarge, NSSize(width: 360, height: 360), "large")] {
                try render(ProgressWidgetView(entry: ProgressEntry(date: .now, snapshots: [reading, second]),
                                              familyOverride: family),
                           name: "widget-\(title)-\(dark ? "dark" : "light")", size: size, dark: dark)
            }
        }
        try render(ProgressWidgetView(entry: ProgressEntry(date: .now, snapshots: [missing]), familyOverride: .systemSmall),
                   name: "widget-missing-temps", size: NSSize(width: 158, height: 158))
    }

    func testEveryConnectionFormFitsItsDeclaredSize() throws {
        let model = store([])
        defer { model.stop() }
        for kind in PrinterKind.allCases {
            try render(AddPrinterView(initialKind: kind).environmentObject(model),
                name: "setup-\(kind.rawValue)", size: NSSize(width: 490, height: [.bambu, .prusaLink].contains(kind) ? 570 : 480))
        }
    }

    func testMenuDropdownHasNoncollapsedViewportAndEmptyState() throws {
        var second = reading; second.id = UUID(); second.name = "Studio"
        let model = store([reading, second])
        defer { model.stop() }
        let host = NSHostingView(rootView: MenuBarView().environmentObject(model))
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertEqual(host.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 400, "Printer list collapsed")
        XCTAssertLessThan(host.fittingSize.height, 750)
        try render(MenuBarView().environmentObject(model), name: "menu-fleet", size: host.fittingSize)
        let empty = store([])
        defer { empty.stop() }
        try render(MenuBarView().environmentObject(empty), name: "menu-empty", size: NSSize(width: 380, height: 300))
    }

    func testStatusCardsAcrossEveryStateAndLargeText() throws {
        for state in [PrintState.idle, .busy, .preparing, .printing, .paused, .finished, .stopped, .cancelled, .failed, .unknown] {
            var sample = reading; sample.state = state
            try render(PrinterCard(snapshot: sample), name: "card-\(state.rawValue)",
                size: NSSize(width: 380, height: 360))
        }
        let offline = reading.offline(PrinterError.timeout)
        try render(PrinterCard(snapshot: offline).dynamicTypeSize(.xxxLarge), name: "card-offline-large-text",
            size: NSSize(width: 380, height: 420))
    }

    func testAllMenuBarModesRenderInLightAndDark() throws {
        for dark in [false, true] {
            try render(HStack(spacing: 24) {
                ForEach(MenuBarDisplayMode.allCases) { mode in MenuBarStatusLabel(snapshot: self.reading, mode: mode) }
            }.padding(), name: "menu-modes-\(dark ? "dark" : "light")",
            size: NSSize(width: 300, height: 70), dark: dark)
        }
    }
}
