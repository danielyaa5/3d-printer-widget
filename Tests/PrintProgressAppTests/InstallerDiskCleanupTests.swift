import XCTest

final class InstallerDiskCleanupTests: XCTestCase {
    func testOnlyAnInstalledCopyCanEjectItsInstaller() {
        let directories = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/fixture/Applications")]
        for path in ["/Applications/Print Progress.app", "/Applications/MyApps/Print Progress.app", "/Users/fixture/Applications/Print Progress.app"] {
            XCTAssertTrue(InstallerDiskCleanup.isInstalled(URL(fileURLWithPath: path), applicationsDirectories: directories))
        }
        for path in ["/Volumes/Print Progress/Print Progress.app", "/private/var/folders/AppTranslocation/fixture/d/Print Progress.app", "/Applications Other/Print Progress.app"] {
            XCTAssertFalse(InstallerDiskCleanup.isInstalled(URL(fileURLWithPath: path), applicationsDirectories: directories))
        }
    }
    private func imageInfo(_ paths: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["images": [["system-entities": paths.map { ["mount-point": $0] }]]], format: .xml, options: 0)
    }

    func testNeverEjectsTheDiskContainingTheRunningApp() throws {
        let data = try imageInfo(["/Volumes/Print Progress", "/Volumes/Other Installer"])
        let result = InstallerDiskCleanup.otherImageVolumes(imageInfo: data,
            runningApp: URL(fileURLWithPath: "/Volumes/Print Progress/Print Progress.app"))
        XCTAssertEqual(result.map(\.path), ["/Volumes/Other Installer"])
    }

    func testInstalledAppCanIdentifyInstallerWithoutMatchingSiblingName() throws {
        let data = try imageInfo(["/Volumes/Print Progress", "/Volumes/Print Progress Other"])
        let result = InstallerDiskCleanup.otherImageVolumes(imageInfo: data,
            runningApp: URL(fileURLWithPath: "/Volumes/Print Progress Other/Print Progress.app"))
        XCTAssertEqual(result.map(\.path), ["/Volumes/Print Progress"])
    }

    func testRejectsRootNestedAndNonVolumePaths() throws {
        let data = try imageInfo(["/", "/Applications", "/Volumes/", "/Volumes/Disk/subfolder", "/tmp/Installer"])
        XCTAssertTrue(InstallerDiskCleanup.otherImageVolumes(imageInfo: data,
            runningApp: URL(fileURLWithPath: "/Applications/Print Progress.app")).isEmpty)
    }

    func testInvalidInfoFailsClosed() {
        XCTAssertTrue(InstallerDiskCleanup.otherImageVolumes(imageInfo: Data("not a plist".utf8),
            runningApp: URL(fileURLWithPath: "/Applications/Print Progress.app")).isEmpty)
    }

    func testNormalVolumesWithoutMatchingReleaseAreNotCandidates() throws {
        XCTAssertTrue(InstallerDiskCleanup.candidates(imageInfo: try imageInfo(["/Volumes/Fixture"]),
            runningApp: URL(fileURLWithPath: "/Applications/Print Progress.app"),
            bundleID: "org.example.PrintProgressMac", version: "1.0", build: "1").isEmpty)
    }
}
