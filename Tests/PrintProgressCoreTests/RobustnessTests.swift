import XCTest
@testable import PrintProgressCore

final class RobustnessTests: XCTestCase {
    private let printer = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://printer.local")

    func testNonfiniteAndOverflowValuesCannotCrashFormatting() throws {
        for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            XCTAssertEqual(ProgressFormat.duration(value), "—")
            XCTAssertEqual(MenuBarPresentation.compactDuration(value), "—")
            XCTAssertEqual(ProgressFormat.temperature(value), "—")
            let snapshot = PrinterSnapshot(profile: printer, state: .printing, progress: value,
                remainingSeconds: value, nozzleTemperature: value, chamberTemperature: value, chamberTarget: value)
            XCTAssertNil(snapshot.nozzleTemperature)
            XCTAssertNil(snapshot.chamberText)
            XCTAssertNil(snapshot.finishDate)
            if !value.isFinite { XCTAssertNil(snapshot.progress) }
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testHugeLayerAndTemperatureReportsRemainReadable() throws {
        let data = Data(#"{"result":{"status":{"print_stats":{"state":"printing","info":{"current_layer":1e300,"total_layer":1e300}},"extruder":{"temperature":1e300}}}}"#.utf8)
        let moonraker = try MoonrakerTelemetry.parse(data, profile: printer)
        XCTAssertNil(moonraker.currentLayer)
        XCTAssertNil(moonraker.totalLayers)
        XCTAssertNil(moonraker.nozzleTemperature)
        var bambu = BambuTelemetry()
        try bambu.merge(Data(#"{"print":{"gcode_state":"RUNNING","mc_percent":50,"layer_num":1e300,"total_layer_num":1e300,"mc_remaining_time":1e308,"chamber_temper":1e300}}"#.utf8))
        let snapshot = try bambu.snapshot(profile: printer)
        XCTAssertNil(snapshot.currentLayer)
        XCTAssertNil(snapshot.remainingSeconds)
        XCTAssertNil(snapshot.chamberTemperature)
    }

    func testBooleanNullAndNonnumericFieldsAreNotTemperaturesOrProgress() throws {
        for value: Any in [true, false, NSNull(), "NaN", "Infinity", "bad", ["unexpected": 1]] {
            XCTAssertNil(TelemetryValue.number(value))
            XCTAssertNil(TelemetryValue.integer(value))
        }
        let data = Data(#"{"state":"Printing","progress":{"completion":true,"printTimeLeft":false}}"#.utf8)
        let snapshot = try OctoPrintTelemetry.parse(data, printerData: nil, profile: printer)
        XCTAssertNil(snapshot.progress)
        XCTAssertNil(snapshot.remainingSeconds)
    }

    func testProgressClampsWithoutInventingTime() {
        for (raw, expected) in [(-1.0, 0.0), (0, 0), (0.5, 0.5), (1, 1), (2, 1)] {
            let snapshot = PrinterSnapshot(profile: printer, progress: raw, remainingSeconds: -20)
            XCTAssertEqual(snapshot.progress, expected)
            XCTAssertNil(snapshot.remainingSeconds)
        }
        XCTAssertEqual(PrinterSnapshot(profile: printer, progress: .nan).percentageText, "—")
    }

    func testDurationBoundariesAndRounding() {
        for (seconds, expected) in [(0.0, "< 1 min"), (59, "< 1 min"), (60, "1 min"),
                                    (61, "2 min"), (3541, "1 hr"), (3601, "1 hr 1 min"),
                                    (86400, "24 hr")] {
            XCTAssertEqual(ProgressFormat.duration(seconds), expected)
        }
        XCTAssertEqual(ProgressFormat.temperature(24.6), "25°")
        XCTAssertEqual(ProgressFormat.temperature(nil), "—")
    }

    func testWidgetCacheAgeBoundariesAndClockSkew() {
        let now = Date(timeIntervalSince1970: 1_000)
        for (age, usable) in [(-6.0, false), (-5, true), (0, true), (120, true), (121, false)] {
            let snapshot = PrinterSnapshot(profile: printer, updatedAt: now.addingTimeInterval(-age))
            XCTAssertEqual(WidgetSnapshotPolicy.canUseCache(snapshot, at: now), usable)
        }
        let needsRefresh = PrinterSnapshot(profile: printer, updatedAt: now, refreshUnavailable: true)
        XCTAssertFalse(WidgetSnapshotPolicy.canUseCache(needsRefresh, at: now))
    }

    func testMenuSelectionFallbacksAndEmptyFleet() {
        let offline = PrinterSnapshot(profile: printer, state: .printing, isOffline: true)
        var other = printer; other.id = UUID()
        let idle = PrinterSnapshot(profile: other, state: .idle)
        XCTAssertNil(MenuBarPresentation.select([]))
        XCTAssertEqual(MenuBarPresentation.text(nil, mode: .percentage), "—")
        XCTAssertEqual(MenuBarPresentation.select([offline, idle])?.id, idle.id)
        XCTAssertEqual(MenuBarPresentation.select([offline, idle], preferredID: "deleted")?.id, idle.id)
        XCTAssertEqual(MenuBarPresentation.select([offline, idle], preferredID: offline.id.uuidString)?.id, offline.id)
        XCTAssertEqual(MenuBarPresentation.select([offline])?.id, offline.id)
    }

    func testAllTerminalStatesSuppressFinishDate() {
        for state in [PrintState.idle, .busy, .paused, .finished, .cancelled, .stopped, .failed, .unknown] {
            let snapshot = PrinterSnapshot(profile: printer, state: state, progress: 0.5, remainingSeconds: 600)
            XCTAssertNil(snapshot.finishDate, state.rawValue)
        }
    }

    func testMQTTFramesAtLengthBoundariesAndEveryFragmentSplit() throws {
        for count in [0, 1, 127, 128, 16383, 16384] {
            let payload = Data(repeating: 42, count: count)
            let encoded = MQTTCodec.packet(0x30, payload)
            for split in Set([0, 1, 2, 3, 4, encoded.count / 2, encoded.count - 1]).filter({ $0 < encoded.count }) {
                var buffer = Data(encoded.prefix(split))
                XCTAssertNil(try MQTTCodec.nextFrame(buffer: &buffer))
                buffer.append(contentsOf: encoded.dropFirst(split))
                XCTAssertEqual(try MQTTCodec.nextFrame(buffer: &buffer)?.body, payload)
                XCTAssertTrue(buffer.isEmpty)
            }
        }
    }

    func testMQTTMalformedLengthAndInvalidPublicationRejectCleanly() {
        for bytes: [UInt8] in [[0x30, 0xff, 0xff, 0xff, 0xff], [0x30, 0xff, 0xff, 0xff, 0x7f]] {
            var buffer = Data(bytes)
            XCTAssertThrowsError(try MQTTCodec.nextFrame(buffer: &buffer))
        }
        for (header, body): (UInt8, [UInt8]) in [(0x30, [0, 8, 65]), (0x30, [0, 1, 255]),
                                                (0x32, [0, 1, 65]), (0x36, [0, 1, 65, 0, 1])] {
            XCTAssertThrowsError(try MQTTCodec.publication(.init(header: header, body: Data(body))))
        }
    }

    func testUnknownStatesNeverBecomeIdleOrFinished() throws {
        let data = Data(#"{"printer":{"state":"FUTURE_STATE"},"job":{}}"#.utf8)
        XCTAssertEqual(try PrusaLinkTelemetry.parse(data, jobData: nil, profile: printer).state, .unknown)
        var creality = CrealityTelemetry()
        try creality.merge(Data(#"{"state":999,"nozzleTemp":20}"#.utf8))
        XCTAssertEqual(try creality.snapshot(profile: printer).state, .unknown)
        let sdcp = Data(#"{"Status":{"PrintInfo":{"Status":999}}}"#.utf8)
        XCTAssertEqual(try SDCPTelemetry.parse(sdcp, profile: printer).state, .unknown)
    }

    func testInvalidTimeoutRejectedBeforeNetworkAccess() async {
        for timeout in [0.0, -1, .nan, .infinity, 301] {
            do { _ = try await PrinterClient.fetch(printer, timeout: timeout); XCTFail("Invalid timeout accepted") }
            catch { guard case PrinterError.configuration = error else { return XCTFail("Wrong error: \(error)") } }
        }
    }

    func testDualNozzleUsesActiveIDRegardlessOfArrayOrderOrLegacyTemperature() throws {
        for (state, expected) in [(2, 221.0), (18, 43.0)] {
            var telemetry = BambuTelemetry()
            let report = """
            {"print":{"gcode_state":"RUNNING","mc_percent":50,"nozzle_temper":43,
              "device":{"extruder":{"state":\(state),"info":[
                {"id":1,"temp":1638443},{"id":0,"temp":14418141}]}}}}
            """
            try telemetry.merge(Data(report.utf8))
            XCTAssertEqual(try telemetry.snapshot(profile: printer).nozzleTemperature, expected)
        }
    }

    func testDualNozzleMissingActiveReportDoesNotSubstituteInactiveTemperature() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"RUNNING","mc_percent":50,"nozzle_temper":43,"device":{"extruder":{"state":2,"info":[{"id":1,"temp":1638443}]}}}}"#.utf8))
        XCTAssertNil(try telemetry.snapshot(profile: printer).nozzleTemperature)
    }
}
