import SwiftUI

@main
struct PrintProgressApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PrintProgressAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var store: ProgressStore
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("menuBarMode") private var menuBarMode: MenuBarDisplayMode = .circle
    @AppStorage("menuBarPrinterID") private var menuBarPrinterID = ""

    init() {
        _store = StateObject(wrappedValue: Self.makeStore())
    }

    @MainActor
    private static func makeStore() -> ProgressStore {
        #if DEBUG
        let demo = CommandLine.arguments.contains("--ui-testing-demo")
        let store = ProgressStore(dependencies: CameraFixtureBootstrap.dependencies ?? (demo ? .demo : .live))
        #else
        let store = ProgressStore()
        #endif
        #if os(macOS)
        // Hidden launches and menu-bar-only sessions must monitor even before
        // SwiftUI creates a window or the user opens the menu content.
        store.start()
        #endif
        return store
    }

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
        WindowGroup("Camera monitor", id: "camera-monitor", for: UUID.self) { $printerID in
            CameraMonitorView(printerID: printerID).environmentObject(store)
        }
        .defaultSize(width: 440, height: 460)
        .windowResizability(.contentMinSize)
        Settings { AppPreferencesView().environmentObject(store) }
        #else
        WindowGroup { ContentView().environmentObject(store) }
        #endif
    }
}
