#if DEBUG && PRINT_PROGRESS_WIDGET_QA
import Foundation
import WidgetKit

extension WidgetControlFixture {
    static var storeDependencies: ProgressStoreDependencies {
        .init(loadProfiles: {
            try prepare(reset: CommandLine.arguments.contains("--widget-qa-reset"))
            try exportIfRequested()
            WidgetCenter.shared.reloadAllTimelines()
            return [profile]
        }, loadSnapshot: { _ in try reading(profile) },
        saveProfiles: { _ in throw PrinterControlError.rejected }, saveSnapshot: SharedVault.saveSnapshot,
        deleteSnapshot: { _ in throw PrinterControlError.rejected }, fetch: { try reading($0) },
        reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }, verificationReports: false,
        control: { try send($0, profile: $1, expected: $2) })
    }
}
#endif
