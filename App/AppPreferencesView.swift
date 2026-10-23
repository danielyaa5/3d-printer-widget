import SwiftUI

struct AppPreferencesView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingGuide = false
    @State private var showingDemo = false
    @State private var widgetDestination: WidgetTapDestination = .companion
    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section("Menu bar") { MenuBarOptionsView().environmentObject(store) }
                #endif
                Section("Widgets") {
                    Picker("Camera snapshot interval", selection: Binding(
                        get: { store.widgetCaptureInterval }, set: { store.setCaptureInterval($0) })) {
                        ForEach(ProgressStore.captureIntervals, id: \.self) { interval in
                            Text("Every \(Int(interval)) seconds").tag(interval)
                        }
                    }
                    .accessibilityIdentifier("camera-capture-interval")
                    Text("Applies to all printers with widget snapshots enabled on this device while the app is monitoring. Longer intervals capture fewer pictures. macOS and iOS schedule widget redraws, so the picture may appear later. Refresh captures a new picture immediately when available.")
                        .font(.caption).foregroundStyle(.secondary)
                    #if os(iOS)
                    Picker("Tap widget to open", selection: $widgetDestination) {
                        ForEach(WidgetTapDestination.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: widgetDestination) { _, value in
                        do { try value.save() } catch { store.errorMessage = error.localizedDescription }
                    }
                    Text("Bambu widgets try Bambu Handy. If it cannot open, or the printer has no supported companion app, Print Progress opens instead. Bambu Handy chooses its opening tab. Refresh and print controls keep their own actions.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    Text("Widgets use the latest verified printer reading and show when it was updated. Open the app for live updates, or use the widget’s refresh arrow to open and refresh the app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Help") {
                    Button("Show setup walkthrough", systemImage: "questionmark.circle") { showingGuide = true }
                    if !store.isDemo {
                        Button("Explore the demo", systemImage: "play.rectangle") { showingDemo = true }
                    }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Preferences")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #endif
        }
        .onAppear {
            do { widgetDestination = try WidgetTapDestination.load() }
            catch { store.errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $showingGuide) { WalkthroughView().environmentObject(store) }
        .sheet(isPresented: $showingDemo) { DemoExperienceView() }
        #if os(macOS)
        .frame(width: 490, height: 470)
        #endif
    }
}

#if os(macOS)
struct MenuBarOptionsView: View {
    @EnvironmentObject private var store: ProgressStore
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("menuBarMode") private var mode: MenuBarDisplayMode = .circle
    @AppStorage("menuBarPrinterID") private var selectedPrinter = ""

    var body: some View {
        Toggle("Show in menu bar", isOn: $showMenuBar).accessibilityIdentifier("show-menu-bar")
        if showMenuBar {
            Picker("Appearance", selection: $mode) {
                ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("menu-bar-appearance")
            Picker("Printer", selection: Binding(get: {
                store.profiles.contains(where: { $0.id.uuidString == selectedPrinter }) ? selectedPrinter : ""
            }, set: { selectedPrinter = $0 })) {
                Text("Automatic (active printer first)").tag("")
                ForEach(store.profiles) { Text($0.name).tag($0.id.uuidString) }
            }
            .accessibilityIdentifier("menu-bar-printer")
            Text("Close all app windows with the red button or ⌘W to hide the Dock icon and keep monitoring in the menu bar. Open app or Settings from the menu bar brings it back. You can also choose Print Progress → Keep Monitoring in Menu Bar. Quit Print Progress stops monitoring and removes the menu bar icon.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
