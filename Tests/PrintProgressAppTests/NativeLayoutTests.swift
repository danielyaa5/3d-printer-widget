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
                try render(ProgressWidgetView(entry: ProgressEntry(date: .now, snapshots: [reading, second], controls: [reading.id: try WidgetControlContext(profile: fixture, snapshot: reading)]),
                                              familyOverride: family),
                           name: "widget-\(title)-\(dark ? "dark" : "light")", size: size, dark: dark)
            }
        }
        try render(ProgressWidgetView(entry: ProgressEntry(date: .now, snapshots: [missing], controls: [missing.id: try WidgetControlContext(profile: fixture, snapshot: missing)]), familyOverride: .systemSmall),
                   name: "widget-missing-temps", size: NSSize(width: 158, height: 158))
    }

    func testNetworkRecoveryCardsInBothAppearances() throws {
        for dark in [false, true] {
            for (error, label) in [(PrinterError.localNetworkAccessDenied, "blocked"),
                                    (.localNetworkUnavailable, "unavailable")] {
                try render(PrinterCard(snapshot: reading.offline(error)),
                           name: "card-network-\(label)-\(dark ? "dark" : "light")",
                           size: NSSize(width: 380, height: 620), dark: dark)
            }
        }
    }

    func testEveryConnectionFormFitsItsDeclaredSize() throws {
        let model = store([])
        defer { model.stop() }
        for kind in PrinterKind.allCases {
            try render(AddPrinterView(initialKind: kind).environmentObject(model),
                name: "setup-\(kind.rawValue)", size: NSSize(width: 490, height: [.bambu, .prusaLink].contains(kind) ? 570 : 480))
        }
    }

    func testBothActivePrintersKeepControlsAndAllTemperaturesInEveryWidgetSize() throws {
        var first = reading; first.jobName = "Desk planter"
        let other = PrinterProfile(name: "Studio", kind: .moonraker, address: "http://studio.invalid")
        var second = first; second.id = other.id; second.name = other.name; second.kind = other.kind
        second.state = .printing; second.jobName = "Cable organizer"; second.progress = 0.28
        let entry = ProgressEntry(date: .now, snapshots: [first, second], controls: [
            first.id: try WidgetControlContext(profile: fixture, snapshot: first),
            second.id: try WidgetControlContext(profile: other, snapshot: second),
        ])
        for dark in [false, true] {
            for (family, size, name) in [(WidgetFamily.systemSmall, NSSize(width: 158, height: 158), "small"),
                                        (.systemMedium, NSSize(width: 360, height: 170), "medium"),
                                        (.systemLarge, NSSize(width: 360, height: 360), "large")] {
                try render(ProgressWidgetView(entry: entry, familyOverride: family),
                    name: "widget-controls-\(name)-\(dark ? "dark" : "light")", size: size, dark: dark)
            }
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
        XCTAssertEqual(host.fittingSize.width, 520, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 400, "Printer list collapsed")
        XCTAssertLessThan(host.fittingSize.height, 850)
        try render(MenuBarView().environmentObject(model), name: "menu-fleet", size: host.fittingSize)
        let empty = store([])
        defer { empty.stop() }
        try render(MenuBarView().environmentObject(empty), name: "menu-empty", size: NSSize(width: 520, height: 300))
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

    func testPrintControlsFitInCardsAndMenuBar() throws {
        let model = ProgressStore(dependencies: .demo)
        for state in [PrintState.printing, .paused] {
            model.setDemoState(state)
            let sample = model.snapshots[DemoData.profiles[0].id]!
            try render(PrinterCard(snapshot: sample, compact: true, showsControls: true).environmentObject(model),
                name: "controls-\(state.rawValue)", size: NSSize(width: 360, height: 420), dark: true)
        }
        try render(MenuBarView().environmentObject(model), name: "menu-with-controls",
            size: NSSize(width: 520, height: 800), dark: true)
    }

    func testFullPercentageFitsWidgetAppAndMenuRingsInBothAppearances() throws {
        var finished = reading
        finished.progress = 1; finished.state = .finished; finished.jobName = "Finished planter"
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            try render(ProgressWidgetView(entry: ProgressEntry(date: .now, snapshots: [finished]), familyOverride: .systemSmall),
                name: "widget-100-\(appearance)", size: NSSize(width: 158, height: 158), dark: dark)
            try render(HStack(spacing: 16) {
                ForEach([0.0, 0.09, 0.99, 1.0], id: \.self) { progress in
                    var sample = finished
                    sample.progress = progress
                    return MenuBarStatusLabel(snapshot: sample, mode: .circleWithPercent)
                }
            }, name: "menu-boundaries-\(appearance)", size: NSSize(width: 180, height: 40), dark: dark)
            let model = store([finished]); defer { model.stop() }
            try render(PrinterCard(snapshot: finished, compact: true).environmentObject(model),
                name: "card-100-\(appearance)", size: NSSize(width: 360, height: 380), dark: dark)
        }
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
