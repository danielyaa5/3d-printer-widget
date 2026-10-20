import Foundation

public enum WidgetSnapshotPolicy {
    /// A recent reading from the app is better evidence than a widget host's network error.
    public static func canUseCache(_ snapshot: PrinterSnapshot?, at now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        return age >= -5 && age <= 120 && snapshot.refreshUnavailable != true
    }
    public static func refreshFailed(profile: PrinterProfile, cached: PrinterSnapshot?, at now: Date = Date()) -> PrinterSnapshot {
        if canUseCache(cached, at: now), let cached { return cached }
        var result = cached ?? PrinterSnapshot(profile: profile, updatedAt: .distantPast)
        result.refreshUnavailable = true
        result.errorMessage = "Open the app to refresh this reading."
        return result
    }
}

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case circle, circleWithPercent, percentage, timeRemaining
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .circle: return "Progress circle"
        case .circleWithPercent: return "Circle with percent"
        case .percentage: return "Percent only"
        case .timeRemaining: return "Time remaining"
        }
    }
}

public enum MenuBarPresentation {
    public static func select(_ snapshots: [PrinterSnapshot], preferredID: String = "") -> PrinterSnapshot? {
        if let selected = snapshots.first(where: { $0.id.uuidString == preferredID }) { return selected }
        return snapshots.first { !$0.isOffline && $0.state.isActive }
            ?? snapshots.first { !$0.isOffline && $0.hasJob }
            ?? snapshots.first { !$0.isOffline }
            ?? snapshots.first
    }
    public static func text(_ snapshot: PrinterSnapshot?, mode: MenuBarDisplayMode) -> String {
        guard let snapshot else { return "—" }
        if snapshot.isOffline { return "Offline" }
        if mode == .percentage { return snapshot.hasJob ? snapshot.percentageText : snapshot.state.title }
        switch snapshot.state {
        case .printing, .preparing:
            guard let remaining = snapshot.remainingSeconds else { return "—" }
            return compactDuration(remaining)
        case .finished: return "Done"
        case .paused: return "Paused"
        default: return snapshot.state.title
        }
    }
    public static func compactDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        guard let minutes = Int(exactly: ceil(seconds / 60)) else { return "—" }
        if minutes == 0 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
