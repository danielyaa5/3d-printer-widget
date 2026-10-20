import SwiftUI

@main
struct PrintProgressApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PrintProgressAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var store = ProgressStore()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("menuBarMode") private var menuBarMode: MenuBarDisplayMode = .circle
    @AppStorage("menuBarPrinterID") private var menuBarPrinterID = ""

    var body: some Scene {
        #if os(macOS)
        Window("Print Progress", id: "printers") {
            ContentView().environmentObject(store)
                .frame(minWidth: 420, idealWidth: 470, minHeight: 440, idealHeight: 650)
        }
        .defaultSize(width: 470, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Keep Monitoring in Menu Bar") { PrintProgressAppDelegate.closeAppWindows() }
                    .disabled(!showMenuBar)
                    .help("Close the app windows while printer monitoring continues in the menu bar.")
            }
        }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environmentObject(store)
        } label: {
            MenuBarStatusLabel(snapshot: MenuBarPresentation.select(
                store.profiles.compactMap { store.snapshots[$0.id] }, preferredID: menuBarPrinterID), mode: menuBarMode)
        }
        .menuBarExtraStyle(.window)
        Settings { AppPreferencesView().environmentObject(store) }
        #else
        WindowGroup { ContentView().environmentObject(store) }
        #endif
    }
}
