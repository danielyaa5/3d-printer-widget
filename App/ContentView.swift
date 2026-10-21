import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var addingPrinter = false
    @State private var editingPrinter: PrinterProfile?
    @State private var removingPrinter: PrinterProfile?
    @State private var showingWidgetHelp = false
    @State private var showingWalkthrough = false
    @State private var showingPreferences = false
    @State private var showingDemo = false
    @State private var checkedOnboarding = false
    @State private var widgetStop: WidgetControlContext?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !store.profiles.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Your printers").font(.title2.bold())
                                Text("A little closer to finished.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Updating printers") }
                        }
                        .padding(.top, 4)
                        ForEach(store.profiles) { profile in
                            PrinterCard(snapshot: store.snapshots[profile.id] ?? PrinterSnapshot(profile: profile),
                                        isConnecting: store.snapshots[profile.id] == nil && store.isRefreshing, showsControls: true)
                            .contextMenu {
                                if !store.isDemo {
                                Button("Edit connection", systemImage: "pencil") { editingPrinter = profile }
                                Button("Remove printer", systemImage: "trash", role: .destructive) { removingPrinter = profile }
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if !store.isDemo {
                                Menu {
                                    Button("Edit connection", systemImage: "pencil") { editingPrinter = profile }
                                    Button("Remove printer", systemImage: "trash", role: .destructive) { removingPrinter = profile }
                                } label: {
                                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 30, height: 28)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .accessibilityLabel("Options for \(profile.name)")
                                .padding(13)
                                }
                            }
                        }
                        HStack(spacing: 7) {
                            Image(systemName: "wifi")
                            Text(store.isDemo ? "Sample readings for exploring the app." : "Connects directly on your local network.")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        Button("Add a desktop or Home Screen widget", systemImage: "square.grid.2x2") {
                            showingWidgetHelp = true
                        }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(ProgressStyle.blue)
                        .frame(maxWidth: .infinity)
                    } else {
                        emptyState
                    }
                }
                .padding(24)
                .frame(maxWidth: 650)
                .frame(maxWidth: .infinity)
            }
            .background(background)
            .navigationTitle("Print Progress")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    if !store.isDemo {
                    Menu {
                        Button("Setup walkthrough", systemImage: "questionmark.circle") { showingWalkthrough = true }
                        Button("Preferences", systemImage: "gearshape") { showingPreferences = true }
                    } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings and help")
                    }
                }
                #endif
                ToolbarItemGroup(placement: .primaryAction) {
                    #if os(macOS)
                    if !store.isDemo {
                    Button { showingWalkthrough = true } label: { Image(systemName: "questionmark.circle") }
                        .help("Setup walkthrough").accessibilityLabel("Setup walkthrough")
                    Button { openSettings() } label: { Image(systemName: "gearshape") }
                        .help("Preferences").accessibilityLabel("Preferences")
                    }
                    #endif
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.isRefreshing || store.profiles.isEmpty).help("Refresh printers")
                        .accessibilityLabel("Refresh printers")
                    Button { addingPrinter = true } label: { Image(systemName: "plus") }
                        .disabled(store.isDemo)
                        .help("Add printer").accessibilityLabel("Add printer")
                }
            }
        }
        .sheet(isPresented: $addingPrinter) { AddPrinterView().environmentObject(store) }
        .sheet(item: $editingPrinter) { profile in AddPrinterView(existing: profile).environmentObject(store) }
        .sheet(isPresented: $showingWalkthrough) {
            WalkthroughView { hasCompletedOnboarding = true; showingWalkthrough = false }.environmentObject(store)
        }
        .sheet(isPresented: $showingPreferences) { AppPreferencesView().environmentObject(store) }
        .sheet(isPresented: $showingDemo) { DemoExperienceView() }
        .sheet(item: $widgetStop) { WidgetStopReview(context: $0).environmentObject(store) }
        .alert("Couldn’t save settings", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("Remove \(removingPrinter?.name ?? "printer")?", isPresented: Binding(get: { removingPrinter != nil }, set: { if !$0 { removingPrinter = nil } }), titleVisibility: .visible) {
            Button("Remove printer", role: .destructive) {
                if let profile = removingPrinter {
                    do { try store.remove(profile) } catch { store.errorMessage = error.localizedDescription }
                }
                removingPrinter = nil
            }
        } message: { Text("This removes the saved connection from this device.") }
        .alert("Add a Print Progress widget", isPresented: $showingWidgetHelp) {
            Button("Got it", role: .cancel) {}
        } message: {
            #if os(macOS)
            Text("Control-click your desktop, choose Edit Widgets, then search for Print Progress. Add a small widget for one printer or a medium widget for both. Control-click a widget to choose its printer. macOS controls refresh timing; open the app or menu bar for live readings.")
            #else
            Text("Touch and hold your Home Screen, tap Edit, then Add Widget and search for Print Progress. Lock Screen widgets are available from Customize. Touch and hold a widget to choose a printer. iOS controls background refresh timing; open the app for live readings.")
            #endif
        }
        .task {
            store.start()
            if !checkedOnboarding {
                checkedOnboarding = true
                if !hasCompletedOnboarding && !store.isDemo {
                    if store.profiles.isEmpty { showingWalkthrough = true }
                    else { hasCompletedOnboarding = true }
                }
            }
        }
        .onOpenURL { url in
            #if os(macOS)
            PrintProgressAppDelegate.prepareToOpenWindow()
            openWindow(id: "printers")
            #endif
            do { widgetStop = try WidgetControlContext.stopContext(from: url) }
            catch { store.errorMessage = error.localizedDescription }
            store.start(); Task { await store.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .active { store.start(); Task { await store.refresh() } }
            else if phase == .background { store.stop() }
            #else
            if phase == .active { store.start(); Task { await store.refresh() } }
            #endif
        }
    }

    private var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(ProgressStyle.green.opacity(0.1)).frame(width: 110, height: 110)
                Image(systemName: "printer.fill").font(.system(size: 46, weight: .light)).foregroundStyle(ProgressStyle.green)
            }
            Text("Your next print, at a glance.").font(.title2.bold()).multilineTextAlignment(.center)
            Text("See progress and time remaining for your connected 3D printers. Everything stays on your network.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("Add your first printer", systemImage: "plus") { addingPrinter = true }
                .buttonStyle(.borderedProminent).tint(ProgressStyle.green).controlSize(.large)
                .padding(.top, 8).accessibilityIdentifier("add-first-printer")
            Button("Explore the demo", systemImage: "play.rectangle") { showingDemo = true }
                .buttonStyle(.plain).foregroundStyle(ProgressStyle.green)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 55)
    }
}

struct PrinterCard: View {
    let snapshot: PrinterSnapshot
    var isConnecting = false
    var compact = false
    var showsControls = false
    private var accent: Color { snapshot.isOffline ? .secondary : ProgressStyle.accent(snapshot.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 20) {
            HStack(spacing: 12) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 20)).foregroundStyle(accent)
                    .frame(width: 43, height: 43)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.name).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(ProgressStyle.status(snapshot)).frame(width: 6, height: 6)
                        Text(isConnecting ? "Connecting…" : snapshot.statusTitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 27)
            }
            if snapshot.hasJob {
                HStack(spacing: 21) {
                    ZStack {
                        ProgressRing(progress: snapshot.progress, color: ProgressStyle.status(snapshot))
                        Text(snapshot.percentageText).font(.system(size: compact ? 20 : 25, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: compact ? 50 : 64, height: compact ? 32 : 40)
                    }
                    .frame(width: compact ? 72 : 88, height: compact ? 72 : 88)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.jobName ?? "Current print").font(.subheadline.weight(.medium)).lineLimit(2)
                        if snapshot.state == .finished && !snapshot.isOffline {
                            Label("Ready when you are", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(accent)
                        } else if let seconds = snapshot.remainingSeconds {
                            Text("\(ProgressFormat.duration(seconds)) remaining").font(.subheadline).foregroundStyle(.secondary)
                            if let finish = snapshot.finishDate {
                                Text("Finishes \(finish, style: .time)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let current = snapshot.currentLayer, let total = snapshot.totalLayers, total > 0 {
                            Text("Layer \(current) of \(total)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
            } else {
                Text(snapshot.isOffline ? "Waiting for a connection" : isConnecting ? "Getting the latest status" : "Ready for the next print")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let nozzle = snapshot.nozzleTemperature {
                    temperature("Nozzle", value: "\(Int(nozzle.rounded()))°", symbol: "thermometer.medium")
                        .accessibilityLabel("Nozzle \(Int(nozzle.rounded())) degrees")
                }
                if let bed = snapshot.bedTemperature {
                    temperature("Bed", value: "\(Int(bed.rounded()))°", symbol: "square.3.layers.3d")
                        .accessibilityLabel("Bed \(Int(bed.rounded())) degrees")
                }
                if let chamber = snapshot.chamberText {
                    temperature("Chamber", value: chamber, symbol: "cube.transparent")
                        .accessibilityLabel("Chamber \(chamber) degrees")
                }
            }
            if showsControls && snapshot.state.isActive {
                Divider()
                PrinterControls(snapshot: snapshot)
            }
            if snapshot.updatedAt != .distantPast && !isConnecting {
                Text("Updated \(snapshot.updatedAt, style: .relative) ago").monospacedDigit()
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Last updated \(snapshot.updatedAt.formatted())")
            }
            if let error = snapshot.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 18 : 22)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("printer-card-\(snapshot.name)")
    }
    private func temperature(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: symbol).fixedSize()
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}
