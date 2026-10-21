// Native click helper for the separately identified, fictional widget QA build.
// Run only with explicit authorization for native UI clicks. It refuses every
// production widget and checks the hit target before posting mouse events.
import AppKit
import ApplicationServices
import CoreGraphics

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func descendants(_ element: AXUIElement) -> [AXUIElement] {
    let direct = children(element)
    return direct.flatMap { [$0] + descendants($0) }
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func contains(_ element: AXUIElement, ancestor: AXUIElement) -> Bool {
    var current = element
    for _ in 0..<12 {
        if CFEqual(current, ancestor) { return true }
        guard let raw = attribute(current, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        current = unsafeBitCast(raw, to: AXUIElement.self)
    }
    return false
}
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
let args = CommandLine.arguments
// There is deliberately no configurable application, window, or coordinate.
guard args.count == 4, args[1] == "--allow-native-click", let index = Int(args[2]), [2, 3].contains(index),
      ["Printing", "Paused"].contains(args[3]) else {
    fail("Usage: widget-qa-click --allow-native-click BUTTON_INDEX EXPECTED_STATE")
}
guard AXIsProcessTrusted() else { fail("Accessibility is unavailable; no click was sent.") }
guard let host = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
    fail("Widget host is not running.")
}
let app = AXUIElementCreateApplication(host.processIdentifier)
let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
guard let window = windows.first(where: { string($0, kAXTitleAttribute) == "Print Progress QA" }) else { fail("QA widget is missing.") }
let elements = descendants(window)
let texts = elements.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }.map { string($0, kAXValueAttribute) }
guard texts.contains("Widget Test"), texts.contains(args[3]) else { fail("QA name/state did not match; no click was sent.") }
let buttons = elements.filter { string($0, kAXRoleAttribute) == kAXButtonRole }
guard buttons.count == 3, let enabled = attribute(buttons[index - 1], kAXEnabledAttribute) as? Bool, enabled else {
    fail("QA control is unavailable; no click was sent.")
}
let target = buttons[index - 1]
guard let position = attribute(target, kAXPositionAttribute), let dimensions = attribute(target, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else { fail("Missing QA control bounds.") }
var origin = CGPoint.zero; var size = CGSize.zero
AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin)
AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size)
fputs("QA control bounds: \(origin), \(size)\n", stderr)
let system = AXUIElementCreateSystemWide()
var point: CGPoint?
for fraction in [0.5, 0.92, 0.08] {
    let candidate = CGPoint(x: origin.x + size.width * fraction, y: origin.y + size.height / 2)
    var hit: AXUIElement?
    if AXUIElementCopyElementAtPosition(system, Float(candidate.x), Float(candidate.y), &hit) == .success, let hit {
        fputs("Hit at \(candidate): \(string(hit, kAXRoleAttribute)) title=\(string(hit, kAXTitleAttribute)) value=\(string(hit, kAXValueAttribute))\n", stderr)
        if contains(hit, ancestor: target) { point = candidate; break }
    }
}
guard let point else { fail("QA button is obscured; no click was sent.") }
let original = CGEvent(source: nil)?.location
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: 1)
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
}
if let original {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?.post(tap: .cghidEventTap)
}
print("Clicked only the fictional QA widget; verify its reported state and command receipt next.")
