import Foundation
import CoreFoundation

enum TelemetryValue {
    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    static func seconds(_ value: Any?) -> Double? { number(value).flatMap { $0 >= 0 ? $0 : nil } }
    static func integer(_ value: Any?) -> Int? { number(value).flatMap(Int.init(exactly:)) }
    static func json(_ data: Data) throws -> [String: Any] {
        guard data.count <= MQTTCodec.maximumPacketSize,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PrinterError.invalidResponse }
        return root
    }
    static func progress(_ value: Any?, state: PrintState, divisor: Double = 100) -> Double? {
        if state == .finished { return 1 }
        if state == .idle || state == .busy { return nil }
        return number(value).map { min(1, max(0, $0 / divisor)) }
    }
}

public enum OctoPrintTelemetry {
    public static func parse(_ jobData: Data, printerData: Data?, profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        let job = try TelemetryValue.json(jobData)
        let printer = try printerData.map(TelemetryValue.json) ?? [:]
        let printerState = TelemetryValue.object(printer["state"])
        guard let raw = printerState["text"] as? String ?? job["state"] as? String else { throw PrinterError.invalidResponse }
        let flags = TelemetryValue.object(printerState["flags"])
        let text = raw.lowercased()
        let offline = text.contains("offline") || text == "closed" || text.contains("disconnected")
        let state: PrintState
        if flags["error"] as? Bool == true || text.contains("error") { state = .failed }
        else if flags["paused"] as? Bool == true || flags["pausing"] as? Bool == true || text.contains("paus") { state = .paused }
        else if flags["cancelling"] as? Bool == true || text.contains("cancel") { state = .cancelled }
        else if flags["printing"] as? Bool == true || text.contains("printing") { state = .printing }
        else if text == "finished" || text == "complete" { state = .finished }
        else if ["operational", "ready", "idle"].contains(text) { state = .idle }
        else { state = .unknown }
        let progress = TelemetryValue.object(job["progress"])
        let file = TelemetryValue.object(TelemetryValue.object(job["job"])["file"])
        let temperatures = TelemetryValue.object(printer["temperature"])
        let toolName = temperatures.keys.filter { $0.hasPrefix("tool") }.sorted().first ?? "tool0"
        let chamber = TelemetryValue.object(temperatures["chamber"])
        return PrinterSnapshot(profile: profile, state: state,
            progress: TelemetryValue.progress(progress["completion"], state: state),
            jobName: ProgressFormat.jobName(file["display"] as? String ?? file["name"] as? String),
            remainingSeconds: state.isActive ? TelemetryValue.seconds(progress["printTimeLeft"]) : nil,
            elapsedSeconds: TelemetryValue.seconds(progress["printTime"]),
            nozzleTemperature: TelemetryValue.number(TelemetryValue.object(temperatures[toolName])["actual"]),
            bedTemperature: TelemetryValue.number(TelemetryValue.object(temperatures["bed"])["actual"]),
            chamberTemperature: TelemetryValue.number(chamber["actual"]), chamberTarget: TelemetryValue.number(chamber["target"]),
            updatedAt: now, isOffline: offline,
            errorMessage: offline ? "The server is reachable, but its printer is disconnected." : job["error"] as? String,
            jobIdentifier: file["path"] as? String ?? file["name"] as? String,
            controlsUnavailable: flags["pausing"] as? Bool == true || text == "pausing" || text == "resuming")
    }
}

public enum PrusaLinkTelemetry {
    public static func parse(_ statusData: Data, jobData: Data?, profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        let root = try TelemetryValue.json(statusData)
        let printer = TelemetryValue.object(root["printer"])
        guard let raw = printer["state"] as? String else { throw PrinterError.invalidResponse }
        let state: PrintState
        switch raw.uppercased() {
        case "IDLE", "READY": state = .idle
        case "BUSY": state = .busy
        case "PREPARING": state = .preparing
        case "PRINTING": state = .printing
        case "PAUSED": state = .paused
        case "FINISHED": state = .finished
        case "STOPPED": state = .stopped
        case "ERROR", "ATTENTION": state = .failed
        default: state = .unknown
        }
        let job = TelemetryValue.object(root["job"])
        let details = try jobData.map(TelemetryValue.json) ?? [:]
        let file = TelemetryValue.object(details["file"])
        let status = TelemetryValue.object(printer["status_printer"])
        return PrinterSnapshot(profile: profile, state: state,
            progress: TelemetryValue.progress(job["progress"] ?? details["progress"], state: state),
            jobName: ProgressFormat.jobName(file["display_name"] as? String ?? file["name"] as? String),
            remainingSeconds: state.isActive ? TelemetryValue.seconds(job["time_remaining"] ?? details["time_remaining"]) : nil,
            elapsedSeconds: TelemetryValue.seconds(job["time_printing"] ?? details["time_printing"]),
            nozzleTemperature: TelemetryValue.number(printer["temp_nozzle"]),
            bedTemperature: TelemetryValue.number(printer["temp_bed"]),
            chamberTemperature: TelemetryValue.number(printer["temp_chamber"]),
            chamberTarget: TelemetryValue.number(printer["target_chamber"]), updatedAt: now,
            errorMessage: state == .failed ? status["message"] as? String : nil,
            jobIdentifier: (TelemetryValue.integer(job["id"] ?? details["id"])).map(String.init),
            controlJobID: TelemetryValue.integer(job["id"] ?? details["id"]),
            controlsUnavailable: TelemetryValue.integer(job["id"] ?? details["id"]) == nil)
    }
}

public enum DuetTelemetry {
    public static func objectModel(_ data: Data, profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        let root = try TelemetryValue.json(data)
        let model = root["result"] == nil ? root : TelemetryValue.object(root["result"])
        let machine = TelemetryValue.object(model["state"])
        guard let raw = machine["status"] as? String else { throw PrinterError.invalidResponse }
        let state: PrintState
        switch raw.lowercased() {
        case "idle": state = .idle
        case "processing": state = .printing
        case "paused", "pausing", "resuming": state = .paused
        case "starting": state = .preparing
        case "busy", "changingtool": state = .busy
        case "halted": state = .failed
        default: state = .unknown
        }
        let job = TelemetryValue.object(model["job"]), file = TelemetryValue.object(job["file"])
        let fileSize = TelemetryValue.number(file["size"])
        let fraction = fileSize.flatMap { size in size > 0 ? TelemetryValue.number(job["filePosition"]).map { $0 / size } : nil }
        let heat = TelemetryValue.object(model["heat"])
        let heaters = heat["heaters"] as? [[String: Any]] ?? []
        let sensors = TelemetryValue.object(model["sensors"])["analog"] as? [[String: Any]] ?? []
        func heater(_ index: Int?) -> (Double?, Double?) {
            guard let index, heaters.indices.contains(index) else { return (nil, nil) }
            let item = heaters[index]
            let sensor = TelemetryValue.integer(item["sensor"])
            let current = sensor.flatMap { sensors.indices.contains($0) ? TelemetryValue.number(sensors[$0]["lastReading"]) : nil }
            let target: Double?
            switch item["state"] as? String {
            case "active", "tuning": target = TelemetryValue.number(item["active"])
            case "standby": target = TelemetryValue.number(item["standby"])
            case "off", "fault", "offline": target = 0
            default: target = nil
            }
            return (current.flatMap { $0 > -270 ? $0 : nil }, target)
        }
        let bed = heater((heat["bedHeaters"] as? [Int])?.first)
        let chamber = heater((heat["chamberHeaters"] as? [Int])?.first)
        let tools = model["tools"] as? [[String: Any]] ?? []
        let tool = tools.first { TelemetryValue.integer($0["number"]) == TelemetryValue.integer(machine["currentTool"]) } ?? tools.first ?? [:]
        let nozzle = heater((tool["heaters"] as? [Int])?.first)
        let times = TelemetryValue.object(job["timesLeft"])
        let remaining = ["file", "filament", "slicer", "layer"].compactMap { TelemetryValue.seconds(times[$0]) }.first { $0 > 0 }
        return PrinterSnapshot(profile: profile, state: state,
            progress: TelemetryValue.progress(fraction, state: state, divisor: 1),
            jobName: ProgressFormat.jobName(file["fileName"] as? String),
            remainingSeconds: state.isActive ? remaining : nil, elapsedSeconds: TelemetryValue.seconds(job["duration"]),
            currentLayer: TelemetryValue.integer(job["layer"]), totalLayers: TelemetryValue.integer(file["numLayers"]),
            nozzleTemperature: nozzle.0, bedTemperature: bed.0, chamberTemperature: chamber.0, chamberTarget: chamber.1,
            updatedAt: now, isOffline: raw.lowercased() == "off")
    }

    public static func legacy(_ data: Data, profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        let root = try TelemetryValue.json(data)
        guard let raw = root["status"] as? String else { throw PrinterError.invalidResponse }
        let state: PrintState
        switch raw {
        case "I": state = .idle
        case "P": state = .printing
        case "A", "D", "R": state = .paused
        case "S", "H": state = .failed
        case "C", "B", "T": state = .preparing
        default: state = .unknown
        }
        let temps = TelemetryValue.object(root["temps"]), chamber = TelemetryValue.object(temps["chamber"])
        let times = TelemetryValue.object(root["timesLeft"])
        return PrinterSnapshot(profile: profile, state: state,
            progress: TelemetryValue.progress(root["fractionPrinted"], state: state),
            jobName: ProgressFormat.jobName(root["fileName"] as? String),
            remainingSeconds: state.isActive ? ["file", "filament", "layer"].compactMap { TelemetryValue.seconds(times[$0]) }.first { $0 > 0 } : nil,
            elapsedSeconds: TelemetryValue.seconds(root["printDuration"]), currentLayer: TelemetryValue.integer(root["currentLayer"]),
            nozzleTemperature: (TelemetryValue.object(temps["heads"])["current"] as? [Any])?.first.flatMap(TelemetryValue.number),
            bedTemperature: TelemetryValue.number(TelemetryValue.object(temps["bed"])["current"]),
            chamberTemperature: TelemetryValue.number(chamber["current"]), chamberTarget: TelemetryValue.number(chamber["active"]), updatedAt: now)
    }
}

public struct CrealityTelemetry {
    private var report: [String: Any] = [:]
    public init() {}
    public mutating func merge(_ data: Data) throws {
        let message = try TelemetryValue.json(data)
        for (key, value) in message { report[key] = value }
    }
    public var hasStatus: Bool {
        guard let state = TelemetryValue.integer(report["state"]), report["nozzleTemp"] != nil else { return false }
        return ![1, 5].contains(state) || report["printProgress"] != nil
    }
    public func snapshot(profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        guard let raw = TelemetryValue.integer(report["state"]) else { throw PrinterError.invalidResponse }
        let state: PrintState
        switch raw {
        case 0: state = .idle
        case 1: state = .printing
        case 2: state = .finished
        case 3: state = .failed
        case 4: state = .cancelled
        case 5: state = .paused
        default: state = .unknown
        }
        return PrinterSnapshot(profile: profile, state: state,
            progress: TelemetryValue.progress(report["printProgress"], state: state),
            jobName: ProgressFormat.jobName(report["printFileName"] as? String),
            remainingSeconds: state.isActive ? TelemetryValue.seconds(report["printLeftTime"]) : nil,
            elapsedSeconds: TelemetryValue.seconds(report["printJobTime"]), currentLayer: TelemetryValue.integer(report["layer"]),
            totalLayers: TelemetryValue.integer(report["TotalLayer"]), nozzleTemperature: TelemetryValue.number(report["nozzleTemp"]),
            bedTemperature: TelemetryValue.number(report["bedTemp0"]),
            chamberTemperature: TelemetryValue.number(report["boxTemp"] ?? report["chamberTemp"]), updatedAt: now,
            jobIdentifier: report["printFileName"] as? String)
    }
}

public enum SDCPTelemetry {
    public static func parse(_ data: Data, profile: PrinterProfile, now: Date = Date()) throws -> PrinterSnapshot {
        let root = try TelemetryValue.json(data)
        let payload = root["Status"] != nil ? root : TelemetryValue.object(root["Data"])
        let status = TelemetryValue.object(payload["Status"]), print = TelemetryValue.object(status["PrintInfo"])
        guard let raw = TelemetryValue.integer(print["Status"]) else { throw PrinterError.invalidResponse }
        let state: PrintState
        let error = TelemetryValue.integer(print["ErrorNumber"]) ?? 0
        if error != 0 { state = .failed }
        else {
            switch raw {
            case 0: state = .idle
            case 1, 10: state = .preparing
            case 2, 3, 4: state = .printing
            case 5, 6: state = .paused
            case 7, 8: state = .stopped
            case 9: state = .finished
            default: state = .unknown
            }
        }
        let layer = TelemetryValue.integer(print["CurrentLayer"]), total = TelemetryValue.integer(print["TotalLayer"])
        let progress = total.flatMap { total in total > 0 ? layer.map { Double($0) / Double(total) } : nil }
        // SDCP v3 specifies milliseconds, not seconds, for both tick fields.
        let elapsed = TelemetryValue.seconds(print["CurrentTicks"]).map { $0 / 1000 }
        let duration = TelemetryValue.seconds(print["TotalTicks"]).map { $0 / 1000 }
        return PrinterSnapshot(profile: profile, state: state,
            progress: TelemetryValue.progress(progress, state: state, divisor: 1),
            jobName: print["Filename"] as? String,
            remainingSeconds: state.isActive ? duration.flatMap { duration in elapsed.map { max(0, duration - $0) } } : nil,
            elapsedSeconds: elapsed, currentLayer: layer, totalLayers: total,
            nozzleTemperature: TelemetryValue.number(status["TempOfNozzle"]), bedTemperature: TelemetryValue.number(status["TempOfHotbed"]),
            chamberTemperature: TelemetryValue.number(status["TempOfBox"]), chamberTarget: TelemetryValue.number(status["TempTargetBox"]),
            updatedAt: now, errorMessage: error != 0 ? "The printer reported SDCP print error \(error). Check its screen for details." : nil,
            jobIdentifier: print["TaskId"] as? String,
            controlsUnavailable: [5, 7, 8].contains(raw))
    }
}
