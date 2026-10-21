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
    func placeholder(in context: Context) -> ProgressEntry {
        ProgressEntry(date: .now, snapshots: WidgetData.sample)
    }
    func snapshot(for configuration: SelectPrinterIntent, in context: Context) async -> ProgressEntry {
        if context.isPreview { return ProgressEntry(date: .now, snapshots: WidgetData.sample) }
        let data = await WidgetData.fresh()
        return ProgressEntry(date: .now, snapshots: data.snapshots, selectedID: configuration.printer?.id, message: data.message, controls: data.controls, feedback: data.feedback)
    }
    func timeline(for configuration: SelectPrinterIntent, in context: Context) async -> Timeline<ProgressEntry> {
        let data = await WidgetData.fresh()
        let entry = ProgressEntry(date: .now, snapshots: data.snapshots, selectedID: configuration.printer?.id, message: data.message, controls: data.controls, feedback: data.feedback)
        let interval: TimeInterval = data.snapshots.contains { $0.state.isActive } ? 600 : 1800
        let pending = data.feedback.values.compactMap(\.blockedUntil).filter { $0 > .now }.min()
        return Timeline(entries: [entry], policy: .after(pending ?? Date().addingTimeInterval(interval)))
    }
}

struct ProgressWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: ProgressEntry
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

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
        .widgetURL(URL(string: "\(WidgetControlContext.urlScheme)://printers"))
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
                single(entry.displayed[0]).padding(10)
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

    private var refreshButton: some View {
        Link(destination: URL(string: "\(WidgetControlContext.urlScheme)://refresh")!) {
            Image(systemName: "arrow.clockwise").font(.caption)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Open app to refresh printer progress")
    }
    private func single(_ printer: PrinterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(printer.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 3)
                refreshButton
            }
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(printer.statusTitle).font(.caption.weight(.medium)).foregroundStyle(ProgressStyle.status(printer))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if printer.state.isActive && !printer.isOffline {
                        Text(ProgressFormat.duration(printer.remainingSeconds)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            Text(entry.feedback[printer.id]?.message ?? (printer.hasJob ? printer.jobName : nil) ?? (printer.isOffline ? "Open app to reconnect" : "Ready for your next print"))
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            temperatures(printer)
            printControls(printer)
            Spacer(minLength: 0)
            if printer.updatedAt != .distantPast {
                Text("Updated \(printer.updatedAt, style: .relative) ago").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private func compact(_ printer: PrinterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(printer.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                if printer.hasJob { Text(printer.percentageText).font(.subheadline.weight(.semibold)).monospacedDigit() }
            }
            if printer.hasJob {
                ProgressView(value: printer.progress ?? 0).tint(ProgressStyle.status(printer))
            }
            HStack(spacing: 4) {
                Circle().fill(ProgressStyle.status(printer)).frame(width: 5, height: 5)
                Text(printer.statusTitle)
                if printer.state.isActive && !printer.isOffline {
                    Text("· \(ProgressFormat.duration(printer.remainingSeconds)) left")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            if let message = entry.feedback[printer.id]?.message ?? (printer.hasJob ? printer.jobName : nil) {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            temperatures(printer)
            printControls(printer)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func printControls(_ printer: PrinterSnapshot) -> some View {
        if printer.hasJob, printer.state.isActive, PrinterControl.supports(printer.kind),
           let context = entry.controls[printer.id] {
            let action: PrinterCommand = printer.state == .paused ? .resume : .pause
            let blocked = entry.feedback[printer.id]?.isBlocked() == true
            let usable = !printer.isOffline && printer.refreshUnavailable != true && printer.controlsUnavailable != true
                && Date().timeIntervalSince(printer.updatedAt) <= 1800
            HStack(spacing: 6) {
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
    private func temperature(_ title: String, current: Double?, target: Double? = nil) -> some View {
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
            Text(title).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.75)
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

struct PrintProgressWidget: Widget {
    let kind = "PrintProgressWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPrinterIntent.self, provider: ProgressProvider()) { entry in
            ProgressWidgetView(entry: entry)
        }
        .configurationDisplayName(widgetDisplayName)
        .description("Your printers’ progress and time remaining, right where you need it.")
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
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

#if !PRINT_PROGRESS_TESTING
@main
struct PrintProgressWidgetBundle: WidgetBundle {
    var body: some Widget { PrintProgressWidget() }
}
#endif
