import XCTest
@testable import PrintProgressCore

final class AdditionalPrinterTests: XCTestCase {
    private func profile(_ kind: PrinterKind) -> PrinterProfile {
        PrinterProfile(name: "Workshop", kind: kind, address: kind.usesWebSocket ? "ws://printer.local:3030/websocket" : "http://printer.local")
    }
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testOctoPrintProgressUsesPercentAndReportedSeconds() throws {
        let reading = try OctoPrintTelemetry.parse(data(#"{"state":"Printing","job":{"file":{"name":"planter.gcode"}},"progress":{"completion":25,"printTime":600,"printTimeLeft":1800}}"#),
            printerData: data(#"{"state":{"text":"Printing","flags":{"printing":true}},"temperature":{"tool0":{"actual":215},"bed":{"actual":60},"chamber":{"actual":35,"target":40}}}"#), profile: profile(.octoPrint))
        XCTAssertEqual(reading.progress, 0.25)
        XCTAssertEqual(reading.remainingSeconds, 1800)
        XCTAssertEqual(reading.jobName, "planter")
        XCTAssertEqual(reading.nozzleTemperature, 215)
        XCTAssertEqual(reading.chamberText, "35° / 40°")
    }
    func testOctoPrintPausedAndIdleDoNotInventCountdownOrOldProgress() throws {
        let paused = try OctoPrintTelemetry.parse(data(#"{"state":"Paused","progress":{"completion":25,"printTimeLeft":600}}"#), printerData: nil, profile: profile(.octoPrint))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.finishDate)
        let idle = try OctoPrintTelemetry.parse(data(#"{"state":"Operational","progress":{"completion":100,"printTimeLeft":600}}"#), printerData: nil, profile: profile(.octoPrint))
        XCTAssertEqual(idle.state, .idle)
        XCTAssertNil(idle.progress)
        XCTAssertNil(idle.remainingSeconds)
        XCTAssertNil(idle.nozzleTemperature)
    }
    func testOctoPrintServerOnlineDoesNotMakeDisconnectedPrinterOnline() throws {
        let reading = try OctoPrintTelemetry.parse(data(#"{"state":"Offline after error","progress":{}}"#), printerData: nil, profile: profile(.octoPrint))
        XCTAssertTrue(reading.isOffline)
        XCTAssertEqual(reading.statusTitle, "Offline")
    }
    func testPrusaLinkStatusAndJobDetails() throws {
        let reading = try PrusaLinkTelemetry.parse(data(#"{"printer":{"state":"PRINTING","temp_nozzle":215,"temp_bed":60},"job":{"progress":40,"time_remaining":900,"time_printing":600}}"#),
            jobData: data(#"{"file":{"name":"PART~1.GCO","display_name":"Planter.gcode"},"progress":39}"#), profile: profile(.prusaLink))
        XCTAssertEqual(reading.state, .printing)
        XCTAssertEqual(reading.progress, 0.4)
        XCTAssertEqual(reading.remainingSeconds, 900)
        XCTAssertEqual(reading.jobName, "Planter")
        XCTAssertNil(reading.chamberTemperature)
    }
    func testPrusaLinkStoppedIsDistinctFromAttentionAndIdleClearsJob() throws {
        for (raw, state) in [("STOPPED", PrintState.stopped), ("ATTENTION", .failed), ("PAUSED", .paused), ("FINISHED", .finished), ("READY", .idle), ("BUSY", .busy)] {
            let reading = try PrusaLinkTelemetry.parse(data("{\"printer\":{\"state\":\"\(raw)\"},\"job\":{\"progress\":50,\"time_remaining\":900}}"), jobData: nil, profile: profile(.prusaLink))
            XCTAssertEqual(reading.state, state)
            if state != .paused { XCTAssertNil(reading.remainingSeconds) }
            if state == .idle || state == .busy { XCTAssertNil(reading.progress) }
            if state == .finished { XCTAssertEqual(reading.progress, 1) }
            XCTAssertNil(reading.finishDate)
        }
    }
    func testDuetObjectModelResolvesActualHeaterSensorsAndSelectedTool() throws {
        let json = #"{"result":{"state":{"status":"processing","currentTool":1},"job":{"file":{"fileName":"0:/gcodes/part.gcode","size":1000,"numLayers":40},"filePosition":250,"duration":600,"layer":10,"timesLeft":{"file":1800}},"tools":[{"number":0,"heaters":[1]},{"number":1,"heaters":[2]}],"heat":{"bedHeaters":[0],"chamberHeaters":[3],"heaters":[{"sensor":2,"active":60},{"sensor":0,"active":0},{"sensor":1,"active":220},{"sensor":3,"active":45,"state":"active"}]},"sensors":{"analog":[{"lastReading":25},{"lastReading":215},{"lastReading":59},{"lastReading":40}]}}}"#
        let reading = try DuetTelemetry.objectModel(data(json), profile: profile(.duet))
        XCTAssertEqual(reading.progress, 0.25)
        XCTAssertEqual(reading.nozzleTemperature, 215)
        XCTAssertEqual(reading.bedTemperature, 59)
        XCTAssertEqual(reading.chamberText, "40° / 45°")
        XCTAssertEqual(reading.currentLayer, 10)
        XCTAssertEqual(reading.totalLayers, 40)
        XCTAssertEqual(reading.remainingSeconds, 1800)
    }
    func testDuetMissingOrNegativeHeaterIndicesAreUnknownAndIdleDoesNotKeepOldProgress() throws {
        let reading = try DuetTelemetry.objectModel(data(#"{"state":{"status":"idle"},"job":{"file":{"size":100},"filePosition":100},"heat":{"bedHeaters":[-1],"chamberHeaters":[99]},"tools":[{"number":0,"heaters":[-1]}]}"#), profile: profile(.duet))
        XCTAssertNil(reading.nozzleTemperature)
        XCTAssertNil(reading.bedTemperature)
        XCTAssertNil(reading.chamberTemperature)
        XCTAssertNil(reading.progress)
    }
    func testDuetLegacyUsesPercentageRatherThanFraction() throws {
        let reading = try DuetTelemetry.legacy(data(#"{"status":"P","fractionPrinted":50,"currentLayer":10,"timesLeft":{"file":600},"temps":{"heads":{"current":[210]},"bed":{"current":60}}}"#), profile: profile(.duet))
        XCTAssertEqual(reading.progress, 0.5)
        XCTAssertEqual(reading.remainingSeconds, 600)
        XCTAssertEqual(reading.nozzleTemperature, 210)
    }
    func testDuetOffHeaterDoesNotShowStoredActiveTargetAsHeating() throws {
        let reading = try DuetTelemetry.objectModel(data(#"{"state":{"status":"busy"},"job":{"file":{"size":100},"filePosition":50},"heat":{"chamberHeaters":[0],"heaters":[{"sensor":0,"state":"off","active":60}]},"sensors":{"analog":[{"lastReading":30}]}}"#), profile: profile(.duet))
        XCTAssertEqual(reading.state, .busy)
        XCTAssertNil(reading.progress)
        XCTAssertNil(reading.remainingSeconds)
        XCTAssertEqual(reading.chamberTarget, 0)
        XCTAssertEqual(reading.chamberText, "30°")
    }
    func testNativeCrealityMergesDeltasAndMapsPausedAndFinished() throws {
        var telemetry = CrealityTelemetry()
        try telemetry.merge(data(#"{"state":1}"#))
        XCTAssertFalse(telemetry.hasStatus)
        try telemetry.merge(data(#"{"nozzleTemp":215}"#))
        XCTAssertFalse(telemetry.hasStatus)
        try telemetry.merge(data(#"{"nozzleTemp":215,"bedTemp0":60,"printProgress":25,"printLeftTime":900,"printFileName":"part.gcode"}"#))
        XCTAssertTrue(telemetry.hasStatus)
        XCTAssertEqual(try telemetry.snapshot(profile: profile(.creality)).progress, 0.25)
        try telemetry.merge(data(#"{"state":5}"#))
        let paused = try telemetry.snapshot(profile: profile(.creality))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.finishDate)
        try telemetry.merge(data(#"{"state":2,"printProgress":99}"#))
        let finished = try telemetry.snapshot(profile: profile(.creality))
        XCTAssertEqual(finished.progress, 1)
        XCTAssertNil(finished.remainingSeconds)
    }
    func testSDCPUsesLayersAndConvertsMillisecondsToSeconds() throws {
        let reading = try SDCPTelemetry.parse(data(#"{"Status":{"PrintInfo":{"Status":3,"CurrentLayer":25,"TotalLayer":100,"CurrentTicks":600000,"TotalTicks":2400000,"Filename":"part.ctb","ErrorNumber":0},"TempOfBox":30,"TempTargetBox":35}}"#), profile: profile(.sdcp))
        XCTAssertEqual(reading.progress, 0.25)
        XCTAssertEqual(reading.elapsedSeconds, 600)
        XCTAssertEqual(reading.remainingSeconds, 1800)
        XCTAssertEqual(reading.chamberText, "30° / 35°")
        XCTAssertNil(reading.nozzleTemperature)
        XCTAssertNil(reading.bedTemperature)
    }
    func testSDCPLegacyEnvelopePausedAndStoppedKeepHonestState() throws {
        for (raw, state) in [(6, PrintState.paused), (8, .stopped), (9, .finished)] {
            let reading = try SDCPTelemetry.parse(data("{\"Data\":{\"Status\":{\"PrintInfo\":{\"Status\":\(raw),\"CurrentLayer\":0,\"TotalLayer\":0}}}}"), profile: profile(.sdcp))
            XCTAssertEqual(reading.state, state)
            XCTAssertNil(reading.finishDate)
            if state != .finished { XCTAssertNil(reading.progress) }
        }
    }
    func testMalformedResponsesDoNotLookLikeIdlePrinters() {
        let empty = data("{}")
        XCTAssertThrowsError(try OctoPrintTelemetry.parse(empty, printerData: nil, profile: profile(.octoPrint)))
        XCTAssertThrowsError(try PrusaLinkTelemetry.parse(empty, jobData: nil, profile: profile(.prusaLink)))
        XCTAssertThrowsError(try DuetTelemetry.objectModel(empty, profile: profile(.duet)))
        XCTAssertThrowsError(try DuetTelemetry.legacy(empty, profile: profile(.duet)))
        XCTAssertThrowsError(try SDCPTelemetry.parse(empty, profile: profile(.sdcp)))
    }
    func testNewConnectionTypesValidateSchemesAndKeepDigestPasswordIntact() throws {
        for kind in [PrinterKind.octoPrint, .prusaLink, .duet, .creality, .sdcp] {
            var p = profile(kind)
            XCTAssertNoThrow(try p.validated())
            p.address = "http://user:password@printer.local"
            XCTAssertThrowsError(try p.validated())
            p.address = "file:///tmp/status.json"
            XCTAssertThrowsError(try p.validated())
        }
        var p = profile(.prusaLink)
        p.username = " local-user "; p.credential = " password with spaces "
        let checked = try p.validated()
        XCTAssertEqual(checked.username, "local-user")
        XCTAssertEqual(checked.credential, p.credential)
        p.username = ""
        XCTAssertThrowsError(try p.validated())
    }
    func testOldProfilesStillDecodeWithoutUsername() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","name":"Workshop","kind":"moonraker","address":"http://printer.local:7125","serialNumber":"","credential":""}"#
        let decoded = try JSONDecoder().decode(PrinterProfile.self, from: data(json))
        XCTAssertEqual(decoded.kind, .moonraker)
        XCTAssertNil(decoded.username)
    }
}
