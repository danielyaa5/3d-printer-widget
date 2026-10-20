import SwiftUI

struct AppPreferencesView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingGuide = false
    @State private var showingDemo = false
    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section("Menu bar") { MenuBarOptionsView().environmentObject(store) }
                #endif
                Section("Widgets") {
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
