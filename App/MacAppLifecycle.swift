#if os(macOS)
import AppKit

@MainActor
final class PrintProgressAppDelegate: NSObject, NSApplicationDelegate {
    private let closingWindows = NSHashTable<NSWindow>.weakObjects()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidUpdate(_ notification: Notification) {
        updateDockVisibility()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // willClose arrives while isVisible can still be true. Keep excluding it
        // through subsequent application updates until AppKit finishes closing it.
        closingWindows.add(window)
        updateDockVisibility()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        closingWindows.remove(window)
        updateDockVisibility()
    }

    private func updateDockVisibility() {
        for window in closingWindows.allObjects where !window.isVisible && !window.isMiniaturized {
            closingWindows.remove(window)
        }
        let hasOpenWindow = NSApp.windows.contains {
            Self.isAppWindow($0) && !closingWindows.contains($0) && ($0.isVisible || $0.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = hasOpenWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    static func isAppWindow(_ window: NSWindow) -> Bool {
        // Status-item popovers and other transient panels must not bring back
        // the Dock icon when the main and Preferences windows are closed.
        window.canBecomeMain && window.level == .normal
    }

    static func prepareToOpenWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
    }

    static func closeAppWindows() {
        NSApp.windows.filter(isAppWindow).forEach { $0.performClose(nil) }
    }
}
#endif
