#if os(macOS)
import AppKit

@MainActor
final class PrintProgressAppDelegate: NSObject, NSApplicationDelegate {
    private let closingWindows = NSHashTable<NSWindow>.weakObjects()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if PRINT_PROGRESS_DIRECT && !PRINT_PROGRESS_TESTING
        InstallerDiskCleanup.afterLaunch()
        #endif
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @discardableResult
    static func recoverHiddenMenuBarApplication(isHidden: Bool, policy: NSApplication.ActivationPolicy,
                                                 windows: [NSWindow], unhide: () -> Void) -> Bool {
        guard isHidden, policy == .accessory else { return false }
        windows.filter(isAppWindow).forEach { $0.orderOut(nil) }
        unhide()
        return true
    }

    func applicationDidUpdate(_ notification: Notification) {
        updateDockVisibility()
        // A launch with open -j leaves the application hidden. A status-item
        // click need not activate it, so waiting for didBecomeActive cannot
        // reliably recover the menu. Normalize the menu-only state before a
        // click, without activating the app or restoring cached main windows.
        Self.recoverHiddenMenuBarApplication(isHidden: NSApp.isHidden, policy: NSApp.activationPolicy(),
            windows: NSApp.windows, unhide: { NSApp.unhideWithoutActivation() })
        #if DEBUG
        Self.writeMenuDiagnostics()
        #endif
    }

    #if DEBUG
    private static var menuVisible = false
    private static var menuOpenCount = 0
    private static var lastMenuVisibilityChange: Date?
    private static var lastMenuReport = Date.distantPast
    static func recordMenuVisibility(_ visible: Bool) {
        if visible && !menuVisible { menuOpenCount += 1 }
        if menuVisible != visible { lastMenuVisibilityChange = .now }
        menuVisible = visible
        writeMenuDiagnostics(force: true)
    }
    private static func writeMenuDiagnostics(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastMenuReport) >= 3,
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        lastMenuReport = .now
        var report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: .now),
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "appHidden": NSApp.isHidden, "appActive": NSApp.isActive,
            "activationPolicy": NSApp.activationPolicy().rawValue, "menuVisible": menuVisible, "menuOpenCount": menuOpenCount,
            "visibleAppWindows": NSApp.windows.filter { isAppWindow($0) && $0.isVisible }.count]
        if let lastMenuVisibilityChange { report["lastMenuVisibilityChange"] = ISO8601DateFormatter().string(from: lastMenuVisibilityChange) }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: cache.appendingPathComponent("PrintProgress-menu-verification.json"), options: .atomic)
        }
    }
    #endif

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
