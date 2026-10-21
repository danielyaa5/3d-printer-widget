import SwiftUI

struct WidgetStopReview: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.dismiss) private var dismiss
    let context: WidgetControlContext
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Stop the print on \(context.snapshot.name)?", systemImage: "stop.circle")
                .font(.title3.bold())
            Text(context.snapshot.jobName ?? "Current print").font(.headline)
            Text("This cancels the job using the printer’s normal cancel routine. The cancelled print can’t be resumed.")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Keep printing", role: .cancel) { dismiss() }
                    .disabled(sending)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Stop print", role: .destructive) {
                    sending = true
                    Task {
                        do {
                            try await store.stopFromWidget(context)
                            dismiss()
                        } catch { self.error = error.localizedDescription; sending = false }
                    }
                }
                .disabled(sending)
                .accessibilityIdentifier("widget-confirm-stop")
            }
            .buttonStyle(.bordered)
        }
        .padding(24).frame(maxWidth: 440)
        .interactiveDismissDisabled(sending)
    }
}
