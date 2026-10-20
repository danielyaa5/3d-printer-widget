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
