import XCTest

final class PrintControlsUITests: XCTestCase {
    func testPauseResumeAndConfirmedStopInTheActualApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo"]
        app.launch()
        defer { app.terminate() }
        let pause = app.buttons["print-pause-Workshop"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        let resume = app.buttons["print-resume-Workshop"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        attach(app, name: "Paused print controls")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        app.buttons["print-stop-Workshop"].tap()
        let keep = app.buttons["Keep printing"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        attach(app, name: "Stop requires confirmation")
        keep.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        app.buttons["print-stop-Workshop"].tap()
        let stop = app.buttons["Stop print"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 3))
        XCTAssertFalse(pause.exists)
        XCTAssertFalse(resume.exists)
        attach(app, name: "Cancelled demo print")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
