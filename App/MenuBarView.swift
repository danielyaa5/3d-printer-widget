#if os(macOS)
import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("menuBarPrinterID") private var preferredPrinter = ""
    @State private var contentHeight: CGFloat = 360

    private var orderedProfiles: [PrinterProfile] {
        let readings = store.profiles.compactMap { store.snapshots[$0.id] }
        guard let first = MenuBarPresentation.select(readings, preferredID: preferredPrinter),
              let profile = store.profiles.first(where: { $0.id == first.id }) else { return store.profiles }
        return [profile] + store.profiles.filter { $0.id != first.id }
    }
    private var summary: String {
        let count = store.profiles.count
        guard count > 0 else { return "Your next print, at a glance" }
        let readings = store.profiles.compactMap { store.snapshots[$0.id] }.filter { !$0.isOffline }
        let printing = readings.filter { $0.state == .printing || $0.state == .preparing }.count
        let paused = readings.filter { $0.state == .paused }.count
        let prefix = "\(count) printer\(count == 1 ? "" : "s")"
        if printing > 0 { return "\(prefix) · \(printing) printing" }
        if paused > 0 { return "\(prefix) · \(paused) paused" }
        return "\(prefix) · Local connection"
    }
    private var maximumContentHeight: CGFloat {
        min(700, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(ProgressStyle.green)
                    .frame(width: 34, height: 34)
                    .background(ProgressStyle.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Print Progress").font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Group {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(store.isRefreshing || store.profiles.isEmpty)
                .help("Refresh printers").accessibilityLabel("Refresh printers")
            }
            .padding(16)

            Divider()
            if store.profiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle").font(.title).foregroundStyle(ProgressStyle.green)
                    Text(store.errorMessage == nil ? "No printers yet" : "Open the app to unlock your printers")
                        .font(.subheadline.weight(.medium))
                    Text("Add a printer in the app to see its progress and temperatures here.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add a printer") { showApp() }.buttonStyle(.borderedProminent).tint(ProgressStyle.green)
                }
                .padding(24).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(orderedProfiles) { profile in
                            PrinterCard(snapshot: store.snapshots[profile.id] ?? PrinterSnapshot(profile: profile),
                                        isConnecting: store.snapshots[profile.id] == nil && store.isRefreshing,
                                        compact: true, showsControls: true)
                            .environment(\.cameraProfile, store.isDemo ? nil : profile)
                        }
                    }
                    .padding(12)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MenuContentHeight.self, value: geometry.size.height)
                    })
                }
                // MenuBarExtra proposes the minimum fitting size. A maximum alone
                // lets a ScrollView collapse to zero; give it a measured viewport.
                .frame(height: min(maximumContentHeight, max(120, contentHeight)))
                .onPreferenceChange(MenuContentHeight.self) { height in
                    if height > 0, abs(contentHeight - height) > 0.5 { contentHeight = height }
                }
                .accessibilityIdentifier("menu-printer-list")
            }

            Divider()
            HStack(spacing: 16) {
                Button(action: showApp) { Label("Open app", systemImage: "arrow.up.forward.app") }
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    PrintProgressAppDelegate.prepareToOpenWindow()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button("Quit Print Progress") { NSApp.terminate(nil) }
                    .help("Stop monitoring and remove the menu bar icon.")
            }
            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).padding(16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { store.start(); await store.refresh() }
    }
    private func showApp() {
        PrintProgressAppDelegate.prepareToOpenWindow()
        openWindow(id: "printers")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif
