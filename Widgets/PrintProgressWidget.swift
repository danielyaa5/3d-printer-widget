import SwiftUI
import WidgetKit
import AppIntents

struct PrinterEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Printer"
    static var defaultQuery = PrinterEntityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PrinterEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PrinterEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [PrinterEntity] {
        try SharedVault.profiles().map { PrinterEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

struct SelectPrinterIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a printer"
    static var description = IntentDescription("Show a specific printer, or leave automatic to show your active printers.")
    @Parameter(title: "Printer") var printer: PrinterEntity?
}

struct ProgressEntry: TimelineEntry {
    var date: Date
    var snapshots: [PrinterSnapshot]
    var selectedID: String?
    var message: String?
    var controls: [UUID: WidgetControlContext] = [:]
    var feedback: [UUID: WidgetControlFeedback] = [:]
    var cameraSnapshots: [UUID: WidgetCameraSnapshot] = [:]
    var cameraAllowedIDs: Set<UUID> = []
    var refreshFeedback: WidgetRefreshFeedback?
    var isGalleryPreview = false

    var displayed: [PrinterSnapshot] {
        if let selectedID { return snapshots.filter { $0.id.uuidString == selectedID } }
        return snapshots.enumerated().sorted { left, right in
            let a = !left.element.isOffline && left.element.state.isActive
            let b = !right.element.isOffline && right.element.state.isActive
            return a == b ? left.offset < right.offset : a
        }.map(\.element)
    }
}

enum WidgetData {
    static func addCameraSnapshots(to entry: inout ProgressEntry, family: WidgetFamily,
                                  loadProfiles: () throws -> [PrinterProfile] = SharedVault.profiles,
                                  loadImage: (UUID) throws -> WidgetCameraSnapshot? = SharedVault.cameraSnapshot) {
        guard family == .systemLarge || family == .systemExtraLarge,
              let profiles = try? loadProfiles() else { return }
        for profile in profiles where profile.camera?.widgetSnapshotsEnabled == true {
            entry.cameraAllowedIDs.insert(profile.id)
            if let image = try? loadImage(profile.id), image.printerID == profile.id,
               image.generation == profile.camera?.widgetSnapshotGeneration {
                entry.cameraSnapshots[profile.id] = image
            }
        }
    }
    static func fresh() async -> (snapshots: [PrinterSnapshot], message: String?, controls: [UUID: WidgetControlContext], feedback: [UUID: WidgetControlFeedback]) {
        #if DEBUG && PRINT_PROGRESS_WIDGET_QA
        return WidgetControlFixture.widgetData()
        #else
        do {
            let profiles = try SharedVault.profiles()
            var snapshots: [UUID: PrinterSnapshot] = [:]
            await withTaskGroup(of: (UUID, PrinterSnapshot).self) { group in
                for profile in profiles {
                    group.addTask {
                        let cached = try? SharedVault.snapshot(for: profile.id)
                        if WidgetSnapshotPolicy.canUseCache(cached), let cached { return (profile.id, cached) }
                        do {
                            let snapshot = try await PrinterClient.fetch(profile, timeout: 7)
                            try? SharedVault.saveSnapshot(snapshot)
                            return (profile.id, snapshot)
                        } catch {
                            // A widget-host permission error does not establish that the
                            // printer is offline. Keep the actual observation timestamp.
                            let latest = (try? SharedVault.snapshot(for: profile.id)) ?? cached
                            return (profile.id, WidgetSnapshotPolicy.refreshFailed(profile: profile, cached: latest))
                        }
                    }
                }
                for await (id, snapshot) in group { snapshots[id] = snapshot }
            }
            let ordered = profiles.compactMap { snapshots[$0.id] }
            #if DEBUG
            try? SharedVault.write(WidgetVerification(snapshots: ordered), account: "widget-verification")
            #endif
            var controls: [UUID: WidgetControlContext] = [:]
            var feedback: [UUID: WidgetControlFeedback] = [:]
            for profile in profiles {
                if let snapshot = snapshots[profile.id] {
                    controls[profile.id] = try? WidgetControlContext(profile: profile, snapshot: snapshot)
                }
                if let value = try? WidgetControlFeedback.load(profile.id),
                   Date().timeIntervalSince(value.createdAt) < 120 || value.isBlocked() {
                    feedback[profile.id] = value
                }
            }
            return (ordered, nil, controls, feedback)
        } catch { return ([], "Open Print Progress to unlock your saved connections.", [:], [:]) }
        #endif
    }

    static func previewEntry(family: WidgetFamily) -> ProgressEntry {
        var entry = ProgressEntry(date: .now, snapshots: sample, isGalleryPreview: true)
        if family == .systemLarge || family == .systemExtraLarge {
            entry.cameraAllowedIDs = Set(entry.snapshots.map(\.id))
        }
        return entry
    }

    static var sample: [PrinterSnapshot] {
        let first = PrinterProfile(name: "Workshop", kind: .bambu, address: "printer.local")
        let second = PrinterProfile(name: "Studio", kind: .moonraker, address: "http://studio.local:7125")
        return [PrinterSnapshot(profile: first, state: .printing, progress: 0.64,
                  jobName: "Desk planter", remainingSeconds: 2520, currentLayer: 128, totalLayers: 200,
                  nozzleTemperature: 220, bedTemperature: 60),
                PrinterSnapshot(profile: second, state: .printing, progress: 0.28,
                  jobName: "Cable organizer", remainingSeconds: 5640, nozzleTemperature: 215, bedTemperature: 60)]
    }
}

struct ProgressProvider: AppIntentTimelineProvider {
    #if DEBUG
    private func recordCameraVerification(_ entry: ProgressEntry, family: WidgetFamily, timeline: Bool) {
        let report = WidgetCameraVerification(generatedAt: .now, family: String(describing: family), timeline: timeline,
            sandboxContainerActive: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            statusCount: entry.snapshots.count, allowedCount: entry.cameraAllowedIDs.count,
            imageCount: entry.cameraSnapshots.count, latestCapture: entry.cameraSnapshots.values.map(\.capturedAt).max())
        try? SharedVault.write(report, account: "widget-camera-verification")
    }
    #endif
    func placeholder(in context: Context) -> ProgressEntry {
        WidgetData.previewEntry(family: context.family)
    }
    func snapshot(for configuration: SelectPrinterIntent, in context: Context) async -> ProgressEntry {
        if context.isPreview { return WidgetData.previewEntry(family: context.family) }
        let data = await WidgetData.fresh()
        var entry = ProgressEntry(date: .now, snapshots: data.snapshots, selectedID: configuration.printer?.id, message: data.message, controls: data.controls, feedback: data.feedback)
        WidgetData.addCameraSnapshots(to: &entry, family: context.family)
        entry.refreshFeedback = try? WidgetRefreshFeedback.load()
        #if DEBUG
        recordCameraVerification(entry, family: context.family, timeline: false)
        #endif
        return entry
    }
    func timeline(for configuration: SelectPrinterIntent, in context: Context) async -> Timeline<ProgressEntry> {
        let data = await WidgetData.fresh()
        var entry = ProgressEntry(date: .now, snapshots: data.snapshots, selectedID: configuration.printer?.id, message: data.message, controls: data.controls, feedback: data.feedback)
        WidgetData.addCameraSnapshots(to: &entry, family: context.family)
        entry.refreshFeedback = try? WidgetRefreshFeedback.load()
        #if DEBUG
        recordCameraVerification(entry, family: context.family, timeline: true)
        #endif
        let interval: TimeInterval = data.snapshots.contains { $0.state.isActive } ? 600 : 1800
        let pending = data.feedback.values.compactMap(\.blockedUntil).filter { $0 > .now }.min()
        var entries = [entry]
        if let feedback = entry.refreshFeedback, feedback.expiresAt > entry.date {
            var cleared = entry; cleared.date = feedback.expiresAt; cleared.refreshFeedback = nil
            entries.append(cleared)
        }
        return Timeline(entries: entries, policy: .after(pending ?? Date().addingTimeInterval(interval)))
    }
}

struct ProgressWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: ProgressEntry
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private var singleLargePrinter: PrinterSnapshot? {
        guard family == .systemLarge else { return nil }
        return entry.displayed.first(where: { entry.cameraAllowedIDs.contains($0.id) })
            ?? (entry.displayed.count == 1 ? entry.displayed.first : nil)
    }

    private var navigationPrinter: PrinterSnapshot? {
        if family == .systemLarge, let camera = entry.displayed.first(where: { entry.cameraAllowedIDs.contains($0.id) }) { return camera }
        return entry.displayed.first
    }

    var body: some View {
        Group {
            #if os(iOS)
            if family == .accessoryRectangular {
                accessoryRectangle
            } else if family == .accessoryCircular {
                accessoryCircle
            } else if family == .accessoryInline {
                if let printer = entry.displayed.first {
                    Text("\(printer.name): \(printer.isOffline || printer.refreshUnavailable == true ? printer.statusTitle : printer.hasJob ? printer.percentageText : printer.statusTitle)")
                } else { Text("Add a printer in Print Progress") }
            } else { systemWidget }
            #else
            systemWidget
            #endif
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(WidgetNavigation.url(printerID: navigationPrinter?.id))
    }

    private var systemWidget: some View {
        Group {
            if entry.displayed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Print Progress", systemImage: "printer.fill").font(.headline)
                    Text(entry.message ?? "Add a printer in the app to see its progress here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(16)
            } else if family == .systemSmall {
                single(entry.displayed[0]).padding(14)
            } else if family == .systemExtraLarge || singleLargePrinter != nil {
                cameraWidget
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Print Progress", systemImage: "printer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        refreshButton
                    }
                    let visible = Array(entry.displayed.prefix(family == .systemLarge ? 4 : 2))
                    if family == .systemMedium {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(visible) { printer in
                                compact(printer).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
                            ForEach(visible) { printer in compact(printer) }
                        }
                        Spacer(minLength: 0)
                    }
                    if let oldest = visible.map(\.updatedAt).filter({ $0 != .distantPast }).min() {
                        Text("Updated \(oldest, style: .relative) ago").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
        }
    }

    private var cameraWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Print Progress", systemImage: "printer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                refreshButton
            }
            let printers = family == .systemExtraLarge ? Array(entry.displayed.prefix(2))
                : singleLargePrinter.map { [$0] } ?? []
            HStack(alignment: .top, spacing: 16) {
                ForEach(printers) { printer in
                    VStack(alignment: .leading, spacing: 7) {
                        cameraImage(printer)
                        compact(printer)
                        if printer.updatedAt != .distantPast {
                            Text("Status updated \(printer.updatedAt, style: .relative) ago")
                                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(12)
    }

    private func cameraImage(_ printer: PrinterSnapshot) -> some View {
        let allowed = entry.cameraAllowedIDs.contains(printer.id)
        let snapshot = allowed ? entry.cameraSnapshots[printer.id] : nil
        let image = snapshot?.image
        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if entry.isGalleryPreview || image != nil {
                    Color.black.opacity(0.92)
                } else {
                    Color.primary.opacity(0.06)
                }
                if entry.isGalleryPreview {
                    GalleryCameraPlaceholder(alternate: printer.kind == .moonraker)
                } else if let image {
                    GeometryReader { geometry in
                        Group {
                            if #available(iOS 18.0, macOS 15.0, *) {
                                Image(decorative: image, scale: 1).resizable()
                                    .widgetAccentedRenderingMode(.fullColor).scaledToFill()
                            } else {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                } else {
                    Link(destination: WidgetNavigation.cameraSetupURL(printerID: printer.id)) {
                        VStack(spacing: 6) {
                            Image(systemName: "camera").font(.title2)
                            Text("Set up camera").font(.caption.weight(.semibold))
                            Text("Connect a camera to show snapshots here.")
                                .font(.system(size: 10)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary).padding(10)
                    .accessibilityLabel("Set up camera for \(printer.name)")
                    .accessibilityIdentifier("widget-camera-setup-\(printer.id.uuidString)")
                }
            }
            .frame(maxWidth: .infinity).frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Decorative pixels must not intercept controls outside the crop.
            .allowsHitTesting(image == nil && !entry.isGalleryPreview)
            if entry.isGalleryPreview {
                Text("Sample camera image").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let snapshot, image != nil {
                Text("Photo age \(snapshot.capturedAt, style: .timer)")
                    .monospacedDigit().contentTransition(.identity)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Camera snapshot captured \(snapshot.capturedAt.formatted())")
            }
        }
        .accessibilityIdentifier("widget-camera-\(printer.id.uuidString)")
    }

    private var refreshButton: some View {
        let request = refreshRequest
        let feedback = entry.refreshFeedback.flatMap { $0.applies(to: request, at: entry.date) ? $0 : nil }
        return Link(destination: request.url) {
            Image(systemName: feedback?.symbol ?? "arrow.clockwise").font(.caption)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain).foregroundStyle(feedback?.phase == .succeeded ? Color.green : Color.secondary)
        .accessibilityLabel(feedback?.label ?? "Refresh printer progress and camera snapshot")
        .help(feedback?.label ?? "Refresh printer progress and camera snapshot")
    }
    private var refreshRequest: WidgetRefreshRequest {
        let printers: [PrinterSnapshot]
        if family == .systemLarge && entry.displayed.contains(where: { entry.cameraAllowedIDs.contains($0.id) }) {
            printers = Array(entry.displayed.filter { entry.cameraAllowedIDs.contains($0.id) }.prefix(1))
        } else {
            printers = Array(entry.displayed.prefix(family == .systemSmall ? 1 : family == .systemLarge ? 4 : 2))
        }
        let ids = Set(printers.map(\.id))
        let cameraIDs = family == .systemLarge || family == .systemExtraLarge ? ids.intersection(entry.cameraAllowedIDs) : []
        return WidgetRefreshRequest(printerIDs: ids, cameraIDs: cameraIDs)
    }
    private func single(_ printer: PrinterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ZStack {
                    ProgressRing(progress: printer.hasJob ? printer.progress : nil,
                                 color: ProgressStyle.status(printer), lineWidth: 5)
                    if printer.hasJob {
                        Text(printer.percentageText).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: 30, height: 24)
                    } else {
                        Image(systemName: "printer").font(.title3).foregroundStyle(.secondary)
                    }
                }.frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Text(printer.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        refreshButton
                    }
                    Text(printer.statusTitle).font(.caption.weight(.medium)).foregroundStyle(ProgressStyle.status(printer))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if printer.state.isActive && !printer.isOffline {
                        Text(ProgressFormat.duration(printer.remainingSeconds)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                if let feedback = entry.feedback[printer.id], let title = feedback.failureTitle {
                    controlFailureLink(title, message: feedback.message, printerID: printer.id)
                } else {
                    Text(entry.feedback[printer.id]?.message ?? (printer.hasJob ? printer.jobName : nil) ?? (printer.isOffline ? "Open app to reconnect" : "Ready for your next print"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.top, 5)
            temperatures(printer).padding(.top, 2)
            Spacer(minLength: 6)
            printControls(printer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private func compact(_ printer: PrinterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Link(destination: WidgetNavigation.url(printerID: printer.id)!) {
                    Text(printer.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }.buttonStyle(.plain)
                Spacer(minLength: 2)
                if printer.hasJob { Text(printer.percentageText).font(.subheadline.weight(.semibold)).monospacedDigit() }
            }
            if printer.hasJob {
                WidgetProgressBar(value: printer.progress ?? 0, tint: ProgressStyle.status(printer))
            }
            HStack(spacing: 4) {
                Circle().fill(ProgressStyle.status(printer)).frame(width: 5, height: 5)
                Text(printer.statusTitle)
                if printer.state.isActive && !printer.isOffline {
                    Text("· \(ProgressFormat.duration(printer.remainingSeconds)) left")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            if let feedback = entry.feedback[printer.id], let title = feedback.failureTitle {
                controlFailureLink(title, message: feedback.message, printerID: printer.id)
            } else if let message = entry.feedback[printer.id]?.message ?? (printer.hasJob ? printer.jobName : nil) {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            if singleLargePrinter?.id == printer.id {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            temperature("Nozzle", current: printer.nozzleTemperature, enlarged: true)
                            temperature("Bed", current: printer.bedTemperature, enlarged: true)
                        }
                        temperature("Chamber", current: printer.chamberTemperature, target: printer.chamberTarget, enlarged: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    printControls(printer, stacked: true)
                        .frame(maxWidth: .infinity)
                }
            } else {
                temperatures(printer)
                printControls(printer)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func controlFailureLink(_ title: String, message: String, printerID: UUID) -> some View {
        Link(destination: WidgetControlFeedback.detailsURL(for: printerID)) {
            Label(title, systemImage: "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(message)")
        .help(message)
    }

    @ViewBuilder
    private func printControls(_ printer: PrinterSnapshot, stacked: Bool = false) -> some View {
        if printer.hasJob, printer.state.isActive, PrinterControl.supports(printer.kind),
           let context = entry.controls[printer.id] {
            let action: PrinterCommand = printer.state == .paused ? .resume : .pause
            let blocked = entry.feedback[printer.id]?.isBlocked() == true
            let usable = !printer.isOffline && printer.refreshUnavailable != true && printer.controlsUnavailable != true
                && Date().timeIntervalSince(printer.updatedAt) <= 1800
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
            layout {
                Button(intent: WidgetPrintActionIntent(context: context, command: action)) {
                    Label(action.title, systemImage: action.symbol).foregroundStyle(ProgressStyle.green)
                        .frame(maxWidth: .infinity, minHeight: 18)
                }
                .tint(ProgressStyle.green)
                .disabled(!usable || blocked || !action.allows(printer.state))
                .accessibilityLabel("\(action.title) print on \(printer.name)")
                if let url = context.stopURL {
                    Link(destination: url) {
                        Label("Stop", systemImage: "stop.fill").foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 18)
                    }
                    .tint(.red).disabled(!usable || blocked)
                    .accessibilityLabel("Review stopping print on \(printer.name)")
                }
            }
            .font(.system(size: 10, weight: .semibold)).buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func temperatures(_ printer: PrinterSnapshot) -> some View {
        HStack(alignment: .top, spacing: 4) {
            temperature("Nozzle", current: printer.nozzleTemperature)
            temperature("Bed", current: printer.bedTemperature)
            temperature("Chamber", current: printer.chamberTemperature, target: printer.chamberTarget)
        }
    }
    private func temperature(_ title: String, current: Double?, target: Double? = nil, enlarged: Bool = false) -> some View {
        let value: String = {
            guard let current else { return "—" }
            let reading = "\(Int(current.rounded()))°"
            if let target, target > 0 { return "\(reading)/\(Int(target.rounded()))°" }
            return reading
        }()
        let spoken: String = {
            guard let current else { return "\(title) temperature unavailable" }
            let reading = "\(title) \(Int(current.rounded())) degrees Celsius"
            if let target, target > 0 { return "\(reading), target \(Int(target.rounded())) degrees Celsius" }
            return reading
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: enlarged ? 10 : 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: enlarged ? 14 : 12, weight: .semibold)).monospacedDigit().foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
    }

    #if os(iOS)
    private var accessoryRectangle: some View {
        Group {
            if let printer = entry.displayed.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text(printer.name).font(.headline)
                    if printer.hasJob {
                        ProgressView(value: printer.progress ?? 0)
                        Text(printer.refreshUnavailable == true ? "Open app to refresh" : printer.isOffline ? "Offline · \(printer.percentageText) last seen" : "\(printer.percentageText) · \(ProgressFormat.duration(printer.remainingSeconds)) left")
                            .font(.caption).lineLimit(1)
                    } else { Text(printer.statusTitle).font(.caption) }
                }
            } else { Text("Add a printer in Print Progress").font(.caption) }
        }
    }
    private var accessoryCircle: some View {
        Group {
            if let printer = entry.displayed.first {
                Gauge(value: printer.progress ?? 0) {
                    Image(systemName: printer.isOffline ? "wifi.slash" : "printer")
                } currentValueLabel: {
                    if printer.refreshUnavailable == true { Image(systemName: "clock.arrow.circlepath") }
                    else if printer.isOffline { Image(systemName: "wifi.slash") }
                    else if printer.hasJob { Text(printer.percentageText) }
                    else { Image(systemName: "printer") }
                }
                .gaugeStyle(.accessoryCircular)
            } else { Image(systemName: "printer") }
        }
    }
    #endif
}

/// Illustrative gallery content; never reads or impersonates a saved camera frame.
private struct GalleryCameraPlaceholder: View {
    var alternate: Bool
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.23), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Path { path in
                    path.move(to: CGPoint(x: width * 0.12, y: height * 0.55))
                    path.addLine(to: CGPoint(x: width * 0.78, y: height * 0.38))
                    path.addLine(to: CGPoint(x: width * 0.96, y: height * 0.88))
                    path.addLine(to: CGPoint(x: width * 0.23, y: height * 1.12))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.24, green: 0.34, blue: 0.39))
                ForEach(0..<7) { index in
                    Rectangle().fill(.white.opacity(0.055)).frame(width: width * 0.72, height: 1)
                        .rotationEffect(.degrees(-10)).offset(y: CGFloat(index) * 10 + 12)
                }
                Image(systemName: alternate ? "shippingbox.fill" : "cup.and.saucer.fill")
                    .font(.system(size: 62, weight: .regular))
                    .foregroundStyle(alternate ? Color.orange : Color.cyan)
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 8, y: 12)
                    .offset(y: 5)
                VStack {
                    HStack {
                        Image(systemName: "video.fill")
                        Text("CAMERA PREVIEW").tracking(1.5)
                        Spacer()
                    }
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }.padding(12)
            }
        }
        .accessibilityLabel("Sample printer camera image")
    }
}

struct PrintProgressWidget: Widget {
    let kind = "PrintProgressWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPrinterIntent.self, provider: ProgressProvider()) { entry in
            ProgressWidgetView(entry: entry)
        }
        .configurationDisplayName(widgetDisplayName)
        .description("Printer progress and time remaining, with optional camera snapshots in large and extra-large widgets.")
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
    private var widgetDisplayName: String {
        #if DEBUG && PRINT_PROGRESS_WIDGET_QA
        "Print Progress QA"
        #else
        "Print Progress"
        #endif
    }
    private var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #endif
    }
}

#if !PRINT_PROGRESS_TESTING
@main
struct PrintProgressWidgetBundle: WidgetBundle {
    var body: some Widget { PrintProgressWidget() }
}
#endif

/// Shape and opacity preserve the filled fraction when the host removes color.
struct WidgetProgressBar: View {
    var value: Double
    var tint: Color
    var fraction: Double { value.isFinite ? min(1, max(0, value)) : 0 }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * fraction)
                    .widgetAccentable()
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Print progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .allowsHitTesting(false)
    }
}
