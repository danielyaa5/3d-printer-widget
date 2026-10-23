#if os(macOS)
import SwiftUI

/// A normal app window for camera monitoring, independent of WidgetKit redraws.
struct CameraMonitorView: View {
    @EnvironmentObject private var store: ProgressStore
    let printerID: UUID?
    var body: some View {
        Group {
            if let profile = store.profiles.first(where: { $0.id == printerID }) {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(profile.name).font(.headline)
                        Spacer()
                        if let reading = store.snapshots[profile.id] {
                            Text(reading.percentageText).monospacedDigit()
                        }
                    }
                    CameraPreview(profile: profile, model: store.cameraSession(for: profile.id))
                    if let reading = store.snapshots[profile.id] {
                        ProgressView(value: reading.progress ?? 0).tint(ProgressStyle.status(reading))
                        Text(reading.statusTitle).font(.subheadline)
                        if reading.state.isActive && !reading.isOffline {
                            Text("\(ProgressFormat.duration(reading.remainingSeconds)) left")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Live camera while this window is visible. Desktop widgets refresh separately.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
                }
            } else {
                ContentUnavailableView("Printer unavailable", systemImage: "printer", description: Text("Open Print Progress to choose a saved printer."))
            }
        }
        .frame(minWidth: 340, idealWidth: 440, minHeight: 330)
        .navigationTitle("Camera monitor")
    }
}
#endif
