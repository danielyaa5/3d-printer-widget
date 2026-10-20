import AppKit

let size = NSSize(width: 680, height: 430)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.90, green: 0.97, blue: 0.94, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
}
let ink = NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.17, alpha: 1)
let muted = NSColor(calibratedRed: 0.27, green: 0.43, blue: 0.37, alpha: 1)
text("Print Progress", x: 42, y: 350, font: .systemFont(ofSize: 31, weight: .semibold), color: ink)
text("Your prints, at a glance.", x: 43, y: 320, font: .systemFont(ofSize: 15), color: muted)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 297, y: 211)); arrow.line(to: NSPoint(x: 380, y: 211))
arrow.move(to: NSPoint(x: 367, y: 224)); arrow.line(to: NSPoint(x: 380, y: 211)); arrow.line(to: NSPoint(x: 367, y: 198))
arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.04, green: 0.56, blue: 0.39, alpha: 1).setStroke(); arrow.stroke()
text("1. Drag the app to Applications.", x: 43, y: 85, font: .systemFont(ofSize: 15, weight: .medium), color: ink)
text("2. Open Print Progress from Applications.", x: 43, y: 58, font: .systemFont(ofSize: 15, weight: .medium), color: ink)
text("The installer disk will eject after the copied app opens.", x: 43, y: 29, font: .systemFont(ofSize: 12), color: muted)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
