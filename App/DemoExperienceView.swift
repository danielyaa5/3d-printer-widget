import SwiftUI

struct DemoExperienceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ProgressStore(dependencies: .demo)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Demo", systemImage: "play.rectangle").font(.headline)
                    Text("Fictional printers. No network connection.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.accessibilityIdentifier("close-demo")
            }
            .padding()
            Divider()
            ContentView().environmentObject(store)
            Divider()
            Picker("Workshop status", selection: Binding(
                get: { store.snapshots[DemoData.profiles[0].id]?.state ?? .printing },
                set: { store.setDemoState($0) })) {
                Text("Printing").tag(PrintState.printing)
                Text("Paused").tag(PrintState.paused)
                Text("Finished").tag(PrintState.finished)
                Text("Cancelled").tag(PrintState.cancelled)
            }
            .pickerStyle(.segmented).padding()
            .accessibilityIdentifier("demo-status")
        }
        #if os(macOS)
        .frame(width: 520, height: 760)
        #endif
    }
}
