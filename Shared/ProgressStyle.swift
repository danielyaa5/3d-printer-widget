import SwiftUI

enum ProgressStyle {
    static let green = Color(red: 0.08, green: 0.60, blue: 0.43)
    static let blue = Color(red: 0.20, green: 0.45, blue: 0.90)
    static func accent(_ kind: PrinterKind) -> Color {
        switch kind {
        case .bambu, .creality, .octoPrint: return green
        case .moonraker: return blue
        case .prusaLink: return .orange
        case .duet: return .indigo
        case .sdcp: return .purple
        }
    }
    static func status(_ snapshot: PrinterSnapshot) -> Color {
        if snapshot.isOffline || snapshot.refreshUnavailable == true { return .secondary }
        switch snapshot.state {
        case .failed: return .red
        case .paused: return .orange
        case .preparing: return .orange
        case .printing, .finished: return accent(snapshot.kind)
        default: return .secondary
        }
    }
}

struct ProgressRing: View {
    var progress: Double?
    var color: Color
    var lineWidth: CGFloat = 7
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.13), lineWidth: lineWidth)
            if let progress {
                Circle().trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }
}
