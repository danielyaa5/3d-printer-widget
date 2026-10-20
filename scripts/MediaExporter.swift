import AppKit
import SwiftUI
import WidgetKit

/// Renders production SwiftUI components with fictional data for documentation.
/// This is an illustrated demo, not footage of a real printer.
@main
struct MediaExporter {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("build/Media.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let date = Date()
        for index in 0..<120 {
            var reading = DemoData.snapshots(date: date)[0]
            switch index {
            case 0..<60:
                reading.progress = 0.64 + Double(index) / 60 * 0.16
                reading.currentLayer = Int((reading.progress ?? 0) * 200)
                reading.remainingSeconds = 2520 - Double(index) * 20
            case 60..<90:
                reading.state = .paused; reading.progress = 0.8; reading.currentLayer = 160
                reading.remainingSeconds = 1320
            default:
                reading.state = .finished; reading.progress = 1; reading.currentLayer = 200
                reading.remainingSeconds = nil
            }
            let view = Showcase(reading: reading)
            try render(view, size: NSSize(width: 1100, height: 700),
                       path: output.appendingPathComponent(String(format: "frame-%03d.png", index)))
        }
        try render(Showcase(reading: DemoData.snapshots(date: date)[0]),
                   size: NSSize(width: 1100, height: 700), path: output.appendingPathComponent("overview.png"))
        try render(Showcase(reading: DemoData.snapshots(date: date)[0])
                       .frame(width: 1100, height: 700)
                       .scaleEffect(900.0 / 700.0)
                       .frame(width: 1440, height: 900)
                       .background(Color(red: 0.035, green: 0.055, blue: 0.06)),
                   size: NSSize(width: 1440, height: 900),
                   path: output.appendingPathComponent("mac-store.png"))
        let demo = ProgressStore(dependencies: .demo)
        try render(MenuBarView().environmentObject(demo), size: NSSize(width: 380, height: 680),
                   path: output.appendingPathComponent("menu-bar.png"))
        for (family, size, name) in [
            (WidgetFamily.systemSmall, NSSize(width: 170, height: 170), "widget-small"),
            (.systemMedium, NSSize(width: 360, height: 170), "widget-medium")
        ] {
            try render(ProgressWidgetView(entry: ProgressEntry(date: date, snapshots: DemoData.snapshots(date: date)),
                                          familyOverride: family), size: size,
                       path: output.appendingPathComponent("\(name).png"))
        }
        print("Rendered fictional demo media in build/Media.noindex")
    }

    @MainActor
    private static func render<V: View>(_ view: V, size: NSSize, path: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        let bounds = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = bounds
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: path)
    }
}

private struct Showcase: View {
    var reading: PrinterSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Print Progress").font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("Your prints, at a glance.").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Text("DEMO · SAMPLE DATA").font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(ProgressStyle.green).padding(12)
                    .background(ProgressStyle.green.opacity(0.1), in: Capsule())
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("THE APP").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    PrinterCard(snapshot: reading).frame(width: 450)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text("YOUR WIDGET").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    ProgressWidgetView(entry: ProgressEntry(date: reading.updatedAt, snapshots: [reading]),
                                       familyOverride: .systemSmall)
                        .frame(width: 180, height: 180).padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 28))
                    Text("YOUR MENU BAR").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    HStack(spacing: 22) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            MenuBarStatusLabel(snapshot: reading, mode: mode)
                        }
                    }
                    .padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    Text("Nozzle, bed and chamber.\nProgress, time remaining and layers.")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 26) {
                Label("Mac + iPhone", systemImage: "macbook.and.iphone")
                Label("Seven local interfaces", systemImage: "wifi")
                Label("Open source", systemImage: "curlybraces")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(50)
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.13), Color(red: 0.035, green: 0.055, blue: 0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(.white)
    }
}
