#if os(macOS)
import AppKit

/// Only the direct-download build calls this. Store builds keep App Sandbox.
enum InstallerDiskCleanup {
    static let markerName = ".print-progress-installer.json"

    static func isInstalled(_ app: URL, applicationsDirectories: [URL]) -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        return applicationsDirectories.contains {
            path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }
    }

    /// A disk must come from hdiutil, contain our matching release marker, and
    /// not contain the running app. Never eject by volume name or force eject.
    static func candidates(imageInfo: Data, runningApp: URL, bundleID: String,
                           version: String, build: String) -> [URL] {
        return otherImageVolumes(imageInfo: imageInfo, runningApp: runningApp).filter { volume in
            guard (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true,
                  let data = try? Data(contentsOf: volume.appendingPathComponent(markerName)),
                  let marker = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  marker == ["bundleID": bundleID, "version": version, "build": build],
                  let source = Bundle(url: volume.appendingPathComponent("Print Progress.app")),
                  source.bundleIdentifier == bundleID,
                  source.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
                  source.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build else { return false }
            return true
        }
    }

    static func otherImageVolumes(imageInfo: Data, runningApp: URL) -> [URL] {
        guard let info = try? PropertyListSerialization.propertyList(from: imageInfo, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return [] }
        let running = runningApp.resolvingSymlinksInPath().standardizedFileURL.path
        let volumes = images.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }.compactMap { entity -> URL? in
            guard let path = entity["mount-point"] as? String else { return nil }
            let volume = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard volume.deletingLastPathComponent().path == "/Volumes",
                  running != volume.path, !running.hasPrefix(volume.path + "/") else { return nil }
            return volume
        }
        return Array(Set(volumes))
    }

    @MainActor static func afterLaunch() {
        guard let id = Bundle.main.bundleIdentifier,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        let appURL = Bundle.main.bundleURL
        // A Gatekeeper-translocated app may have a path outside its original
        // disk image. Only a copy in an Applications folder can do cleanup.
        let directories = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        guard isInstalled(appURL, applicationsDirectories: directories) else { return }
        // Let the installed app finish opening before touching its installer.
        Task {
            try? await Task.sleep(for: .seconds(3))
            let volumes = await Task.detached(priority: .utility) {
                let task = Process(), output = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                task.arguments = ["info", "-plist"]
                task.standardOutput = output
                task.standardError = FileHandle.nullDevice
                do {
                    try task.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    guard task.terminationStatus == 0 else { return [URL]() }
                    return candidates(imageInfo: data, runningApp: appURL, bundleID: id, version: version, build: build)
                } catch { return [] }
            }.value
            for volume in volumes {
                // A busy disk stays mounted; installation and monitoring still work.
                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }
    }
}
#endif
