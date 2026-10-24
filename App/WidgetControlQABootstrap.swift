#if DEBUG && PRINT_PROGRESS_WIDGET_QA
import Foundation
import WidgetKit

extension WidgetControlFixture {
    static var storeDependencies: ProgressStoreDependencies {
        .init(loadProfiles: {
            try prepare(reset: CommandLine.arguments.contains("--widget-qa-reset"))
            if CommandLine.arguments.contains("--widget-qa-camera-off") {
                try SharedVault.write(false, account: "widget-qa-camera-enabled")
                try SharedVault.saveProfiles([profile])
            } else if CommandLine.arguments.contains("--widget-qa-camera-on") {
                try SharedVault.delete(account: "widget-qa-camera-enabled")
                try SharedVault.saveProfiles([profile])
            }
            if CommandLine.arguments.contains("--widget-qa-reject-controls") {
                try SharedVault.write(true, account: "widget-qa-reject-controls")
            } else if CommandLine.arguments.contains("--widget-qa-allow-controls") {
                try SharedVault.delete(account: "widget-qa-reject-controls")
            }
            if let index = CommandLine.arguments.firstIndex(of: "--widget-qa-photo-step"),
               CommandLine.arguments.count > index + 1,
               let step = Int(CommandLine.arguments[index + 1]) {
                try saveTestPhoto(step: step)
            }
            // Preview the normal Details route without dispatching a command.
            if CommandLine.arguments.contains("--widget-qa-control-error-preview") {
                try SharedVault.saveProfiles([profile])
                try WidgetControlFeedback.save(.failure(
                    PrinterControlError.bambuRejected(reason: "mqtt message verify failed"),
                    command: .pause, at: .now), for: profile.id)
            }
            try exportIfRequested()
            WidgetCenter.shared.reloadAllTimelines()
            return [profile]
        }, loadSnapshot: { _ in try reading(profile) },
        saveProfiles: { _ in throw PrinterControlError.rejected }, saveSnapshot: SharedVault.saveSnapshot,
        deleteSnapshot: { _ in throw PrinterControlError.rejected }, fetch: { try reading($0) },
        reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }, autoStart: false, verificationReports: false,
        cameraSource: { _ in throw PrinterControlError.unsupported },
        loadCameraSnapshot: SharedVault.cameraSnapshot,
        control: { try send($0, profile: $1, expected: $2) })
    }
}
#endif
