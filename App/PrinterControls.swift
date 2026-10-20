import SwiftUI

struct PrinterControls: View {
    @EnvironmentObject private var store: ProgressStore
    let snapshot: PrinterSnapshot
    private struct StopRequest {
        let snapshot: PrinterSnapshot
        let profile: PrinterProfile?
    }
    @State private var stopping: StopRequest?

    var body: some View {
        let configuredProfile = store.profiles.first { $0.id == snapshot.id }
        VStack(alignment: .leading, spacing: 9) {
            if PrinterControl.supports(snapshot.kind) {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    HStack(spacing: 10) {
                        let action: PrinterCommand = snapshot.state == .paused ? .resume : .pause
                        Button {
                            Task { await store.control(action, expected: snapshot, expectedProfile: configuredProfile) }
                        } label: { Label(action.title, systemImage: action.symbol).frame(minWidth: 72) }
                            .tint(ProgressStyle.green).foregroundStyle(ProgressStyle.green)
                            .disabled(!store.commandEnabled(action, snapshot: snapshot))
                            .accessibilityIdentifier("print-\(action.rawValue)-\(snapshot.name)")
                        Button(role: .destructive) { stopping = StopRequest(snapshot: snapshot, profile: configuredProfile) } label: {
                            Label("Stop", systemImage: "stop.fill").frame(minWidth: 58)
                        }
                        .tint(.red).foregroundStyle(.red)
                        .disabled(!store.commandEnabled(.stop, snapshot: snapshot))
                        .accessibilityLabel("Stop print on \(snapshot.name)")
                        .accessibilityIdentifier("print-stop-\(snapshot.name)")
                        Spacer(minLength: 0)
                        if store.pendingControls[snapshot.id] != nil {
                            ProgressView().controlSize(.small).accessibilityLabel("Waiting for printer")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.regular)
                }
                if let message = store.controlMessages[snapshot.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("print-control-status-\(snapshot.name)")
                } else if snapshot.isOffline || snapshot.refreshUnavailable == true || Date().timeIntervalSince(snapshot.updatedAt) > 60 {
                    Text("Refresh to use print controls.").font(.caption).foregroundStyle(.secondary)
                } else if snapshot.controlsUnavailable == true {
                    Text("Controls are unavailable in the printer’s current state.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(snapshot.kind == .creality ? "For print controls, connect this printer through Moonraker." : "Print controls aren’t available for this connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Stop the print on \(snapshot.name)?", isPresented: Binding(
            get: { stopping != nil }, set: { if !$0 { stopping = nil } }), presenting: stopping) { expected in
            Button("Stop print", role: .destructive) {
                Task { await store.control(.stop, expected: expected.snapshot, expectedProfile: expected.profile) }
                stopping = nil
            }
            Button("Keep printing", role: .cancel) { stopping = nil }
        } message: { expected in
            Text("Cancel \(expected.snapshot.jobName ?? "the current print")? It can’t be resumed afterward. This runs the printer’s normal cancel routine.")
        }
    }
}
