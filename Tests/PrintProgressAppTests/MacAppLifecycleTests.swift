import AppKit
import XCTest

@MainActor
final class MacAppLifecycleTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 200, height: 150),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func delegate() -> PrintProgressAppDelegate {
        let delegate = PrintProgressAppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return delegate
    }

    private func update(_ delegate: PrintProgressAppDelegate) {
        delegate.applicationDidUpdate(Notification(name: NSApplication.didUpdateNotification))
    }

    func testLastWindowCloseHidesDockAndReopeningRestoresIt() {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let delegate = delegate()
        let main = window()
        defer { main.close(); app.setActivationPolicy(previousPolicy) }

        main.makeKeyAndOrderFront(nil)
        update(delegate)
        XCTAssertEqual(app.activationPolicy(), .regular)
        main.close()
        update(delegate)
        XCTAssertEqual(app.activationPolicy(), .accessory)

        PrintProgressAppDelegate.prepareToOpenWindow()
        main.makeKeyAndOrderFront(nil)
        update(delegate)
        XCTAssertEqual(app.activationPolicy(), .regular)
    }

    func testPreferencesKeepsDockUntilBothWindowsClose() {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let delegate = delegate()
        let main = window(), preferences = window()
        defer { main.close(); preferences.close(); app.setActivationPolicy(previousPolicy) }

        main.orderFront(nil)
        preferences.orderFront(nil)
        update(delegate)
        main.close()
        update(delegate)
        XCTAssertEqual(app.activationPolicy(), .regular)
        preferences.close()
        update(delegate)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }

    func testMenuActivationRecoveryKeepsMainWindowHiddenBeforeUnhiding() {
        let main = window()
        let panel = NSPanel(contentRect: NSRect(x: -2000, y: -2000, width: 200, height: 150),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .statusBar
        defer { main.close(); panel.close() }
        main.orderFront(nil); panel.orderFront(nil)
        var recoveries = 0
        XCTAssertTrue(PrintProgressAppDelegate.recoverHiddenMenuBarApplication(isHidden: true,
            policy: .accessory, windows: [main, panel]) {
                XCTAssertFalse(main.isVisible, "Main windows must be ordered out before unhide")
                XCTAssertTrue(panel.isVisible, "The menu panel must be preserved")
                recoveries += 1
            })
        XCTAssertEqual(recoveries, 1)
        main.orderFront(nil)
        for (hidden, policy) in [(false, NSApplication.ActivationPolicy.accessory), (true, .regular)] {
            XCTAssertFalse(PrintProgressAppDelegate.recoverHiddenMenuBarApplication(isHidden: hidden,
                policy: policy, windows: [main]) { XCTFail("Normal activation must be preserved") })
            XCTAssertTrue(main.isVisible)
        }
    }
    func testMenuBarPanelDoesNotRestoreDockWithoutAppWindows() {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let delegate = delegate()
        let panel = NSPanel(contentRect: NSRect(x: -2000, y: -2000, width: 200, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        defer { panel.close(); app.setActivationPolicy(previousPolicy) }

        panel.orderFront(nil)
        update(delegate)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }
}
