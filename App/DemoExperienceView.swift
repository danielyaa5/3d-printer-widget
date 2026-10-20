import SwiftUI

struct DemoExperienceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ProgressStore(dependencies: .demo)
    @State private var state: PrintState = .printing

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
            Picker("Workshop status", selection: $state) {
                Text("Printing").tag(PrintState.printing)
                Text("Paused").tag(PrintState.paused)
                Text("Finished").tag(PrintState.finished)
            }
            .pickerStyle(.segmented).padding()
            .accessibilityIdentifier("demo-status")
        }
        .onChange(of: state) { _, value in store.setDemoState(value) }
        #if os(macOS)
        .frame(width: 520, height: 760)
        #endif
    }
}
