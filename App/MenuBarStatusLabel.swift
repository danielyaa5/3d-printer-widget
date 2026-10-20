#if os(macOS)
import SwiftUI
import AppKit

struct MenuBarStatusLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    var snapshot: PrinterSnapshot?
    var mode: MenuBarDisplayMode

    var body: some View {
        Image(nsImage: mode == .circle || mode == .circleWithPercent ? circleImage : textImage)
            .renderingMode(.original)
            .accessibilityLabel(accessibilityTitle)
            .help(accessibilityTitle)
    }

    private static let teal = NSColor(srgbRed: 0.02, green: 0.46, blue: 0.37, alpha: 1)
    private static let mint = NSColor(srgbRed: 0.37, green: 1, blue: 0.79, alpha: 1)
    private var foregroundColor: NSColor { colorScheme == .dark ? Self.mint : Self.teal }

    private var accessibilityTitle: String {
        guard let snapshot else { return "Print Progress. Add a printer to get started." }
        return "\(snapshot.name): \(snapshot.statusTitle), \(snapshot.percentageText). Click for printer details."
    }

    private var textImage: NSImage {
        // MenuBarExtra can apply the system text color to a Text label. Render
        // original-color artwork for text modes, just as for the progress circle.
        let text = NSAttributedString(string: MenuBarPresentation.text(snapshot, mode: mode), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular),
            .foregroundColor: foregroundColor,
        ])
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width) + 2, height: 22), flipped: false) { bounds in
            text.draw(at: NSPoint(x: 1, y: floor((bounds.height - size.height) / 2)))
            return true
        }
        image.isTemplate = false
        return image
    }

    private var circleImage: NSImage {
        let progress = snapshot?.isOffline == false ? snapshot?.progress ?? 0 : 0
        let includePercent = mode == .circleWithPercent
        let centerText: String
        if snapshot?.isOffline == true { centerText = "–" }
        else if let progress = snapshot?.progress { centerText = "\(Int((progress * 100).rounded()))" }
        else { centerText = "–" }
        let isDark = colorScheme == .dark
        let teal = Self.teal
        let mint = Self.mint
        let foreground = foregroundColor
        let track = isDark ? mint.withAlphaComponent(0.24) : teal.withAlphaComponent(0.25)
        // Preserve the app icon's mint and teal instead of letting macOS tint a template.
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 18, height: 18))
            circle.lineWidth = 1.8
            track.setStroke(); circle.stroke()
            if progress > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 1.8; arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: 9,
                              startAngle: 90, endAngle: 90 - CGFloat(min(1, progress)) * 360, clockwise: true)
                foreground.setStroke(); arc.stroke()
            }
            if includePercent {
                let text = NSAttributedString(string: centerText, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
                    .foregroundColor: foreground,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: (22 - size.width) / 2, y: (22 - size.height) / 2))
            } else {
                Self.drawNozzle(teal: teal, mint: mint, isDark: isDark)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawNozzle(teal: NSColor, mint: NSColor, isDark: Bool) {
        // A simple, optically centered silhouette stays recognizable at 22 points.
        let stem = NSBezierPath(roundedRect: NSRect(x: 8.5, y: 13.5, width: 5, height: 3),
                                xRadius: 0.6, yRadius: 0.6)
        (isDark ? mint : teal).setFill(); stem.fill()

        let shoulder = NSBezierPath()
        shoulder.move(to: NSPoint(x: 7.5, y: 14))
        shoulder.line(to: NSPoint(x: 14.5, y: 14))
        shoulder.line(to: NSPoint(x: 15.5, y: 12.5))
        shoulder.line(to: NSPoint(x: 14.5, y: 10.5))
        shoulder.line(to: NSPoint(x: 7.5, y: 10.5))
        shoulder.line(to: NSPoint(x: 6.5, y: 12.5))
        shoulder.close()
        NSGradient(starting: mint, ending: teal)?.draw(in: shoulder, angle: -90)
        shoulder.lineWidth = 0.6
        (isDark ? mint : teal).setStroke(); shoulder.stroke()

        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: 8.2, y: 10.5))
        tip.line(to: NSPoint(x: 13.8, y: 10.5))
        tip.line(to: NSPoint(x: 11.8, y: 6.2))
        tip.line(to: NSPoint(x: 10.2, y: 6.2))
        tip.close()
        (isDark ? mint : teal).setFill(); tip.fill()

        let filament = NSBezierPath()
        filament.lineWidth = 1.1; filament.lineCapStyle = .round
        filament.move(to: NSPoint(x: 11, y: 6.2))
        filament.line(to: NSPoint(x: 11, y: 4.9))
        (isDark ? mint : teal).setStroke(); filament.stroke()
    }
}
#endif
