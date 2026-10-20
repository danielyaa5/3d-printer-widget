import XCTest
@testable import PrintProgressCore

final class TelemetryTests: XCTestCase {
    private var klipper: PrinterProfile { PrinterProfile(name: "Workshop", kind: .moonraker, address: "http://printer.local:7125") }
    private var bambu: PrinterProfile { PrinterProfile(name: "Studio", kind: .bambu, address: "printer.local", serialNumber: "DEMO123", credential: "example") }

    func testMoonrakerPrintingProgressAndRemainingEstimate() throws {
        let data = Data(#"{"result":{"status":{"print_stats":{"state":"printing","filename":"folder/part.gcode","print_duration":600,"info":{"current_layer":12,"total_layer":48}},"display_status":{"progress":0.25},"virtual_sdcard":{"progress":0.3},"extruder":{"temperature":220},"heater_bed":{"temperature":60}}}}"#.utf8)
        let snapshot = try MoonrakerTelemetry.parse(data, profile: klipper)
        XCTAssertEqual(snapshot.state, .printing)
        XCTAssertEqual(snapshot.progress, 0.25)
        XCTAssertEqual(snapshot.remainingSeconds, 1800)
        XCTAssertEqual(snapshot.jobName, "part")
        XCTAssertEqual(snapshot.currentLayer, 12)
        XCTAssertEqual(snapshot.totalLayers, 48)
    }
    func testIdleDoesNotShowOldJobProgress() throws {
        let data = Data(#"{"result":{"status":{"print_stats":{"state":"standby"},"display_status":{"progress":1}}}}"#.utf8)
        let snapshot = try MoonrakerTelemetry.parse(data, profile: klipper)
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertNil(snapshot.progress)
        XCTAssertFalse(snapshot.hasJob)
    }
    func testFinishedForcesFullProgressAndStopsCountdown() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"FINISH","mc_percent":99,"mc_remaining_time":4}}"#.utf8))
        let snapshot = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(snapshot.progress, 1)
        XCTAssertNil(snapshot.remainingSeconds)
        XCTAssertNil(snapshot.finishDate)
    }
    func testPartialBambuMessagesAndPackedH2DTemperatures() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"RUNNING","mc_percent":40,"mc_remaining_time":12,"subtask_name":"Planter.gcode.3mf","device":{"bed":{"info":{"temp":3932220}},"extruder":{"info":[{"temp":14418140}]}}}}"#.utf8))
        try telemetry.merge(Data(#"{"print":{"mc_percent":41,"device":{"bed":{"info":{"other":1}}}}}"#.utf8))
        XCTAssertTrue(telemetry.hasStatus)
        let snapshot = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(snapshot.progress, 0.41)
        XCTAssertEqual(snapshot.remainingSeconds, 720)
        XCTAssertEqual(snapshot.jobName, "Planter")
        XCTAssertEqual(snapshot.bedTemperature, 60)
        XCTAssertEqual(snapshot.nozzleTemperature, 220)
    }
    func testBambuStatusWaitsForProgressInsteadOfReturningUnrelatedTelemetry() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"RUNNING","nozzle_temper":210}}"#.utf8))
        XCTAssertFalse(telemetry.hasStatus)
        try telemetry.merge(Data(#"{"print":{"mc_percent":0}}"#.utf8))
        XCTAssertTrue(telemetry.hasStatus)
    }
    func testOfflineRetainsLastRealReadingAndTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let original = PrinterSnapshot(profile: klipper, state: .printing, progress: 0.5, remainingSeconds: 600, updatedAt: timestamp)
        let offline = original.offline(PrinterError.timeout)
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.progress, 0.5)
        XCTAssertEqual(offline.updatedAt, timestamp)
        XCTAssertNil(offline.finishDate)
        XCTAssertEqual(offline.statusTitle, "Offline")
        XCTAssertTrue(offline.isStale(at: timestamp.addingTimeInterval(301)))
    }
    func testBambuCancelledTaskDoesNotBecomePrinterFault() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"FAILED","mc_percent":12,"print_error":50348044}}"#.utf8))
        let reading = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(reading.state, .cancelled)
        XCTAssertEqual(reading.statusTitle, "Cancelled")
        XCTAssertEqual(reading.printerErrorCode, 0x0300400C)
        XCTAssertNil(reading.errorMessage)
        XCTAssertNil(reading.remainingSeconds)
        XCTAssertNil(reading.finishDate)
    }
    func testBambuOtherFailuresKeepTheirErrorCodeAndWarning() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"FAILED","print_error":50348035}}"#.utf8))
        let reading = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(reading.state, .failed)
        XCTAssertEqual(reading.printerErrorCode, 0x03004003)
        XCTAssertTrue(reading.errorMessage?.contains("03004003") == true)
    }
    func testBambuFailureWithoutCancellationCodeIsNotGuessedCancelled() throws {
        for errorField in ["", ",\"print_error\":-1", ",\"print_error\":4294967296"] {
            var telemetry = BambuTelemetry()
            try telemetry.merge(Data("{\"print\":{\"gcode_state\":\"FAILED\"\(errorField)}}".utf8))
            XCTAssertEqual(try telemetry.snapshot(profile: bambu).state, .failed)
        }
    }
    func testBambuStoppedJobWithoutPrintErrorUsesNeutralStatus() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"FAILED","mc_percent":0,"print_error":0,"mc_remaining_time":30}}"#.utf8))
        let reading = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(reading.state, .stopped)
        XCTAssertEqual(reading.statusTitle, "Stopped")
        XCTAssertEqual(reading.progress, 0)
        XCTAssertTrue(reading.hasJob)
        XCTAssertNil(reading.errorMessage)
        XCTAssertNil(reading.remainingSeconds)
        XCTAssertNil(reading.finishDate)
        XCTAssertEqual(MenuBarPresentation.text(reading, mode: .timeRemaining), "Stopped")
    }
    func testBambuNewJobClearsCancellationWhenErrorIsReset() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"FAILED","print_error":50348044}}"#.utf8))
        try telemetry.merge(Data(#"{"print":{"gcode_state":"RUNNING","mc_percent":1,"print_error":0}}"#.utf8))
        let reading = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(reading.state, .printing)
        XCTAssertEqual(reading.printerErrorCode, 0)
        XCTAssertNil(reading.errorMessage)
    }
    func testPausedDoesNotCountDown() {
        let paused = PrinterSnapshot(profile: bambu, state: .paused, progress: 0.3, remainingSeconds: 600)
        XCTAssertNil(paused.finishDate)
    }
    func testMalformedTelemetryRejected() {
        XCTAssertThrowsError(try MoonrakerTelemetry.parse(Data(#"{"result":{}}"#.utf8), profile: klipper))
        var telemetry = BambuTelemetry()
        XCTAssertThrowsError(try telemetry.merge(Data("[]".utf8)))
    }
    func testAddressValidationAndNormalization() throws {
        var profile = klipper
        profile.address = " http://printer.local:7125/ "
        XCTAssertEqual(try profile.validated().address, "http://printer.local:7125")
        for invalid in ["printer.local", "ftp://printer.local", "http://user:password@printer.local", "http://printer.local?x=1"] {
            profile.address = invalid
            XCTAssertThrowsError(try profile.validated())
        }
        var other = bambu
        other.address = "http://printer.local"
        XCTAssertThrowsError(try other.validated())
        other.address = "printer.local"; other.serialNumber = "DEMO/123"
        XCTAssertThrowsError(try other.validated())
    }
    func testDurationFormattingAndUnknownValues() {
        XCTAssertEqual(ProgressFormat.duration(nil), "—")
        XCTAssertEqual(ProgressFormat.duration(-1), "—")
        XCTAssertEqual(ProgressFormat.duration(59), "< 1 min")
        XCTAssertEqual(ProgressFormat.duration(60), "1 min")
        XCTAssertEqual(ProgressFormat.duration(3600), "1 hr")
        XCTAssertEqual(ProgressFormat.duration(5400), "1 hr 30 min")
    }
    func testH2DChamberCurrentAndHeatTarget() throws {
        var telemetry = BambuTelemetry()
        try telemetry.merge(Data(#"{"print":{"gcode_state":"RUNNING","mc_percent":50,"device":{"ctc":{"info":{"temp":3932212}}}}}"#.utf8))
        let reading = try telemetry.snapshot(profile: bambu)
        XCTAssertEqual(reading.chamberTemperature, 52)
        XCTAssertEqual(reading.chamberTarget, 60)
        XCTAssertEqual(reading.chamberText, "52° / 60°")
    }
    func testK1ChamberSensorDoesNotUseFanTargetAsHeatTarget() throws {
        let data = Data(#"{"result":{"status":{"print_stats":{"state":"standby"},"temperature_sensor chamber_temp":{"temperature":24.65},"temperature_fan chamber_fan":{"temperature":24.64,"target":35}}}}"#.utf8)
        let reading = try MoonrakerTelemetry.parse(data, profile: klipper)
        XCTAssertEqual(reading.chamberTemperature, 24.65)
        XCTAssertNil(reading.chamberTarget)
    }
    func testGenericChamberHeaterReportsItsOwnTarget() throws {
        let data = Data(#"{"result":{"status":{"print_stats":{"state":"standby"},"temperature_sensor chamber":{"temperature":30},"heater_generic chamber":{"temperature":45,"target":60}}}}"#.utf8)
        let reading = try MoonrakerTelemetry.parse(data, profile: klipper)
        XCTAssertEqual(reading.chamberTemperature, 45)
        XCTAssertEqual(reading.chamberTarget, 60)
    }
    func testChamberDiscoveryIncludesSensorsAndExcludesControlMacros() throws {
        let data = Data(#"{"result":{"objects":["gcode_macro CHAMBER_HEATER_ON","temperature_sensor chamber_temp","temperature_fan chamber_fan","temperature_sensor mcu_temp","heater_generic enclosure"]}}"#.utf8)
        XCTAssertEqual(try MoonrakerTelemetry.chamberObjects(from: data),
                       ["temperature_sensor chamber_temp", "temperature_fan chamber_fan", "heater_generic enclosure"])
    }
}
