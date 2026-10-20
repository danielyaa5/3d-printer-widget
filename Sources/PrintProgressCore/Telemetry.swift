import Foundation

private func number(_ value: Any?) -> Double? {
    TelemetryValue.number(value)
}
private func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

public enum MoonrakerTelemetry {
    public static func chamberObjects(from data: Data) throws -> [String] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let names = dictionary(root?["result"])["objects"] as? [String] ?? []
        return names.filter { name in
            let name = name.lowercased()
            return (name.contains("chamber") || name.contains("enclosure"))
                && ["heater_generic ", "temperature_sensor ", "temperature_fan "].contains(where: name.hasPrefix)
        }
    }
    public static func parse(_ data: Data, profile: PrinterProfile, estimatedSeconds: Double? = nil,
                             now: Date = Date()) throws -> PrinterSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let status = result["status"] as? [String: Any],
              let print = status["print_stats"] as? [String: Any], let rawState = print["state"] as? String else {
            throw PrinterError.invalidResponse
        }
        let state: PrintState
        switch rawState {
        case "standby", "ready": state = .idle
        case "printing": state = .printing
        case "paused": state = .paused
        case "complete": state = .finished
        case "cancelled": state = .cancelled
        case "error": state = .failed
        default: state = .unknown
        }
        let display = dictionary(status["display_status"]), sd = dictionary(status["virtual_sdcard"])
        let reportedProgress = number(display["progress"]) ?? number(sd["progress"])
        let progress = state == .finished ? 1 : state == .idle ? nil : reportedProgress
        let elapsed = number(print["print_duration"])
        var remaining: Double?
        if state == .printing || state == .paused {
            if let elapsed, let progress, progress > 0.01, progress < 1, elapsed > 0 {
                remaining = max(0, elapsed / progress - elapsed)
            } else if let estimatedSeconds, let elapsed {
                remaining = max(0, estimatedSeconds - elapsed)
            }
        }
        let info = dictionary(print["info"])
        // Prefer a real chamber heater, then a passive sensor. A temperature fan's
        // target is a cooling threshold and must never be presented as a heat target.
        let chamberNames = status.keys.filter { name in
            let lower = name.lowercased()
            return (lower.contains("chamber") || lower.contains("enclosure"))
                && ["heater_generic ", "temperature_sensor ", "temperature_fan "].contains(where: lower.hasPrefix)
        }.sorted { left, right in
            func rank(_ value: String) -> Int {
                value.hasPrefix("heater_generic ") ? 0 : value.hasPrefix("temperature_sensor ") ? 1 : 2
            }
            return rank(left) == rank(right) ? left < right : rank(left) < rank(right)
        }
        let chamberName = chamberNames.first
        let chamber = chamberName.map { dictionary(status[$0]) } ?? [:]
        return PrinterSnapshot(profile: profile, state: state, progress: progress,
             jobName: ProgressFormat.jobName(print["filename"] as? String), remainingSeconds: remaining,
             elapsedSeconds: elapsed, currentLayer: TelemetryValue.integer(info["current_layer"]) ?? TelemetryValue.integer(sd["layer"]),
             totalLayers: TelemetryValue.integer(info["total_layer"]) ?? TelemetryValue.integer(sd["layer_count"]),
             nozzleTemperature: number(dictionary(status["extruder"])["temperature"]),
             bedTemperature: number(dictionary(status["heater_bed"])["temperature"]),
             chamberTemperature: number(chamber["temperature"]),
             chamberTarget: chamberName?.hasPrefix("heater_generic ") == true ? number(chamber["target"]) : nil,
             updatedAt: now, jobIdentifier: print["filename"] as? String)
    }
}

public struct BambuTelemetry {
    private var report: [String: Any] = [:]
    public init() {}
    public mutating func merge(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrinterError.invalidResponse
        }
        Self.merge(&report, root)
    }
    private static func merge(_ target: inout [String: Any], _ delta: [String: Any]) {
        for (key, value) in delta {
            if var existing = target[key] as? [String: Any], let nested = value as? [String: Any] {
                merge(&existing, nested); target[key] = existing
            } else { target[key] = value }
        }
    }
    public var hasStatus: Bool {
        let print = dictionary(report["print"])
        guard let state = print["gcode_state"] as? String else { return false }
        return print["mc_percent"] != nil || ["IDLE", "FINISH", "FAILED", "UNKNOWN"].contains(state)
    }
    public func snapshot(profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        let print = dictionary(report["print"])
        guard let rawState = print["gcode_state"] as? String else { throw PrinterError.invalidResponse }
        let printError = number(print["print_error"]).flatMap { UInt32(exactly: $0) }
        let state: PrintState
        switch rawState {
        case "IDLE": state = .idle
        case "PREPARE": state = .preparing
        case "RUNNING": state = .printing
        case "PAUSE": state = .paused
        case "FINISH": state = .finished
        // Bambu also reports FAILED when a task is cancelled. Its published
        // 0300400C code identifies cancellation rather than a printer fault.
        case "FAILED":
            if printError == 0x0300400C { state = .cancelled }
            else if printError == 0 { state = .stopped }
            else { state = .failed }
        default: state = .unknown
        }
        let errorMessage: String?
        if state == .failed, let printError, printError != 0 {
            errorMessage = "Printer error \(String(format: "%08X", printError)). Check the printer or Bambu Handy for details."
        } else { errorMessage = nil }
        let device = dictionary(print["device"])
        let bed = dictionary(dictionary(device["bed"])["info"])
        let chamber = dictionary(dictionary(device["ctc"])["info"])
        let extruderSystem = dictionary(device["extruder"])
        let extruders = extruderSystem["info"] as? [[String: Any]]
        func currentTemperature(_ packed: Any?) -> Double? {
            guard let packed = number(packed), packed >= 0, packed <= Double(UInt32.max) else { return nil }
            return Double(UInt32(packed) & 0xFFFF)
        }
        let nozzle: Double?
        if let packedState = number(extruderSystem["state"]).flatMap(UInt32.init(exactly:)),
           packedState & 0xF > 1 {
            // Bambu's multi-extruder status stores the active tool ID in bits
            // 4–7. Array order and the legacy nozzle field do not identify it.
            let activeID = Int((packedState >> 4) & 0xF)
            let active = extruders?.first { TelemetryValue.integer($0["id"]) == activeID }
            nozzle = currentTemperature(active?["temp"])
        } else {
            nozzle = number(print["nozzle_temper"]) ?? currentTemperature(extruders?.first?["temp"])
        }
        return PrinterSnapshot(profile: profile, state: state,
            progress: state == .finished ? 1 : state == .idle ? nil : number(print["mc_percent"]).map { $0 / 100 },
            jobName: ProgressFormat.jobName(print["subtask_name"] as? String ?? print["gcode_file"] as? String),
            remainingSeconds: state.isActive ? number(print["mc_remaining_time"]).map { $0 * 60 } : nil,
            currentLayer: TelemetryValue.integer(print["layer_num"]), totalLayers: TelemetryValue.integer(print["total_layer_num"]),
            nozzleTemperature: nozzle,
            bedTemperature: number(print["bed_temper"]) ?? currentTemperature(bed["temp"]),
            chamberTemperature: currentTemperature(chamber["temp"]) ?? number(print["chamber_temper"]),
            chamberTarget: number(chamber["temp"]).flatMap { value in
                guard value >= 0, value <= Double(UInt32.max) else { return nil }
                return Double(UInt32(value) >> 16)
            } ?? number(print["chamber_target_temper"]), printerErrorCode: printError, updatedAt: now,
            errorMessage: errorMessage,
            jobIdentifier: ["task_id", "subtask_id"].compactMap { key -> String? in
                guard let value = print[key], !(value is NSNull) else { return nil }
                let text = String(describing: value)
                return text.isEmpty || text == "0" ? nil : text
            }.joined(separator: ":").nilIfEmpty)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
