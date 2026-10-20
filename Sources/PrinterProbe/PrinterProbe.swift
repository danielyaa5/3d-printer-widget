import Foundation
import PrintProgressCore

@main
struct PrinterProbe {
    static func main() async {
        guard (2...3).contains(CommandLine.arguments.count) else {
            print("Usage: printer-probe /path/to/private-printer-settings.json [--verify-certificate]")
            exit(2)
        }
        do {
            let profiles = try JSONDecoder().decode([PrinterProfile].self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            var failed = false
            for profile in profiles {
                do {
                    let snapshot = try await PrinterClient.fetch(profile)
                    print("\(profile.name): \(snapshot.statusTitle), \(snapshot.percentageText), remaining \(ProgressFormat.duration(snapshot.remainingSeconds)); live response verified")
                    print("  Job name: \(snapshot.jobName == nil ? "unavailable" : "present"); nozzle/bed readings: \(snapshot.nozzleTemperature != nil && snapshot.bedTemperature != nil ? "present" : "unavailable")")
                    print("  Chamber: \(snapshot.chamberText ?? "unavailable")")
                    if CommandLine.arguments.contains("--verify-certificate"), profile.kind == .bambu {
                        var mismatched = profile
                        mismatched.certificateFingerprint = String(repeating: "0", count: 64)
                        do {
                            _ = try await PrinterClient.fetch(mismatched)
                            print("Certificate mismatch unexpectedly accepted."); failed = true
                        } catch PrinterError.certificateChanged {
                            print("Certificate mismatch correctly rejected before authentication.")
                        }
                    }
                } catch {
                    failed = true
                    print("\(profile.name): \(error.localizedDescription)")
                }
            }
            if failed { exit(1) }
        } catch {
            print("Could not read the private printer settings.")
            exit(1)
        }
    }
}
