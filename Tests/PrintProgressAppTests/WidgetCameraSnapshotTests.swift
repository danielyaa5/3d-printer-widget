import XCTest
import AppKit
import SwiftUI
import WidgetKit

@MainActor
final class WidgetCameraSnapshotTests: XCTestCase {
    func testConnectingSnapshotStaysSeparateUntilANewLiveFrameArrives() async throws {
        let ports = try fixturePorts()
        var profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        profile.camera?.widgetSnapshotGeneration = UUID()
        let old = try WidgetCameraSnapshot.capture(image(), printerID: profile.id, capturedAt: Date().addingTimeInterval(-300),
            generation: profile.camera?.widgetSnapshotGeneration)
        let model = CameraPreviewModel(resolve: { profile in
            try await Task.sleep(nanoseconds: 300_000_000)
            return try await PrinterCameraSource.resolve(profile)
        }, loadSnapshot: { _ in old }, onCertificate: { _ in })
        let viewer = UUID(), requestedAt = Date()
        model.show(viewer, profile: profile); defer { model.hide(viewer) }
        XCTAssertEqual(model.connectingSnapshot, old)
        XCTAssertNil(model.image, "A saved photo must never be presented or captured as live video")
        let fresh = try await model.captureWidgetSnapshot(profile: profile, capturedAfter: requestedAt)
        XCTAssertGreaterThanOrEqual(fresh.capturedAt, requestedAt)
        XCTAssertEqual(fresh.image?.width, 160)
        XCTAssertNil(model.connectingSnapshot)
        XCTAssertEqual(model.message, "Live camera")
    }

    func testConnectingSnapshotRejectsOtherPrintersOldConnectionsAndRevokedPermission() throws {
        var profile = PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        profile.camera?.widgetSnapshotGeneration = UUID()
        let valid = try WidgetCameraSnapshot.capture(image(), printerID: profile.id, capturedAt: .now,
            generation: profile.camera?.widgetSnapshotGeneration)
        let wrongPrinter = try WidgetCameraSnapshot.capture(image(), printerID: UUID(), capturedAt: .now,
            generation: profile.camera?.widgetSnapshotGeneration)
        let oldConnection = try WidgetCameraSnapshot.capture(image(), printerID: profile.id, capturedAt: .now, generation: UUID())
        for snapshot in [wrongPrinter, oldConnection] {
            let model = CameraPreviewModel(loadSnapshot: { _ in snapshot }, onCertificate: { _ in })
            let viewer = UUID(); model.show(viewer, profile: profile)
            XCTAssertNil(model.connectingSnapshot); model.hide(viewer)
        }
        let model = CameraPreviewModel(loadSnapshot: { _ in valid }, onCertificate: { _ in })
        let viewer = UUID(); model.show(viewer, profile: profile)
        XCTAssertNotNil(model.connectingSnapshot)
        profile.camera?.widgetSnapshotsEnabled = false
        model.show(viewer, profile: profile)
        XCTAssertNil(model.connectingSnapshot); model.hide(viewer)
        let locked = CameraPreviewModel(loadSnapshot: { _ in throw PrinterError.keychain(-25308) }, onCertificate: { _ in })
        profile.camera?.widgetSnapshotsEnabled = true
        locked.show(viewer, profile: profile)
        XCTAssertNil(locked.connectingSnapshot); locked.hide(viewer)
    }

    func testWidgetRefreshCapturesBeforeBackgroundDeadlineAndConfirmsOnlySavedFreshPicture() async throws {
        let ports = try fixturePorts()
        var profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        profile.camera?.widgetSnapshotGeneration = UUID()
        let fixture = profile
        var captures: [WidgetCameraSnapshot] = [], feedback: [WidgetRefreshFeedback] = []
        var failSave = false
        var deps = ProgressStoreDependencies(loadProfiles: { [fixture] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false)
        deps.saveCameraSnapshot = { photo in
            if failSave { throw PrinterError.keychain(-25308) }
            captures.append(photo)
        }
        deps.saveWidgetRefreshFeedback = { feedback.append($0) }
        let store = ProgressStore(dependencies: deps); defer { store.stop() }
        let request = WidgetRefreshRequest(printerIDs: [profile.id], cameraIDs: [profile.id])
        await store.refreshFromWidget(request)
        XCTAssertEqual(captures.count, 1); XCTAssertEqual(feedback.map(\.phase), [.refreshing, .succeeded])
        let tappedAt = Date()
        await store.refreshFromWidget(request)
        XCTAssertEqual(captures.count, 2, "An explicit refresh must bypass the 5-second background interval")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(captures.last).capturedAt, tappedAt)
        XCTAssertLessThan(captures[1].capturedAt.timeIntervalSince(captures[0].capturedAt), 5)
        XCTAssertEqual(feedback.last?.phase, .succeeded)
        failSave = true
        await store.refreshFromWidget(request)
        XCTAssertEqual(captures.count, 2)
        XCTAssertEqual(feedback.last?.phase, .failed, "Receiving a frame is not success if the widget cannot read the saved picture")
        XCTAssertEqual(store.cameraSession(for: profile.id).activeViewerCount, 0)
    }

    func testRefreshLinksAndFeedbackAreScopedAndExpire() throws {
        let printer = UUID(), other = UUID(), date = Date()
        let request = WidgetRefreshRequest(printerIDs: [printer], cameraIDs: [printer])
        XCTAssertEqual(WidgetRefreshRequest.decode(request.url), request)
        XCTAssertNil(WidgetRefreshRequest.decode(URL(string: "\(WidgetControlContext.urlScheme)://refresh?printer=invalid")!))
        XCTAssertNil(WidgetRefreshRequest.decode(WidgetRefreshRequest(printerIDs: [printer], cameraIDs: [other]).url))
        let feedback = WidgetRefreshFeedback(request: request, phase: .succeeded, updatedAt: date)
        XCTAssertTrue(feedback.applies(to: request, at: date))
        XCTAssertFalse(feedback.applies(to: request, at: date.addingTimeInterval(30)))
        XCTAssertFalse(feedback.applies(to: .init(printerIDs: [other], cameraIDs: []), at: date))
        XCTAssertFalse(WidgetRefreshFeedback(request: .init(printerIDs: [printer], cameraIDs: []), phase: .succeeded, updatedAt: date)
            .applies(to: request, at: date), "A status-only refresh must not confirm a camera refresh")
    }

    func testFiveSecondCadenceWithAndWithoutVisibleVideo() async throws {
        let ports = try fixturePorts()
        let profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)")
        var now = Date(timeIntervalSince1970: 1000), count = 0
        var deps = ProgressStoreDependencies(loadProfiles: { [profile] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, now: { now },
            autoStart: false, verificationReports: false)
        deps.saveCameraSnapshot = { _ in count += 1 }
        let store = ProgressStore(dependencies: deps); defer { store.stop() }
        store.setWidgetSnapshotsEnabled(true, for: profile.id)
        var deadline = Date().addingTimeInterval(5)
        while count < 1, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(count, 1)
        now = now.addingTimeInterval(4.9)
        await store.refresh()
        XCTAssertEqual(count, 1, "Status refresh must not capture before five seconds")
        now = now.addingTimeInterval(0.1)
        await store.refresh()
        deadline = Date().addingTimeInterval(5)
        while count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(count, 2)
        await store.refresh()
        XCTAssertEqual(count, 2)
        let viewer = UUID(), session = store.cameraSession(for: profile.id)
        session.show(viewer, profile: profile)
        XCTAssertTrue(session.hasVisibleViewer)
        now = now.addingTimeInterval(5)
        await store.refresh()
        deadline = Date().addingTimeInterval(5)
        while count < 3, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(count, 3, "Visible video should use five-second captures")
        session.hide(viewer)
        XCTAssertFalse(session.hasVisibleViewer)
        XCTAssertEqual(session.activeViewerCount, 0)
        now = now.addingTimeInterval(5)
        await store.refresh()
        deadline = Date().addingTimeInterval(5)
        while count < 4, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(count, 4, "Closing video must keep the five-second interval")
        XCTAssertEqual(session.activeViewerCount, 0, "Snapshot requests do not count as visible viewers")
    }

    func testFrequentSnapshotsReuseConnectionAndExpireWhenRequestsStop() async throws {
        let ports = try fixturePorts()
        var profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        let model = CameraPreviewModel(onCertificate: { _ in })
        defer { model.stop() }
        let first = try await model.captureWidgetSnapshot(profile: profile)
        XCTAssertNotNil(model.image, "Keep the connection available between captures")
        XCTAssertFalse(model.hasVisibleViewer)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let second = try await model.captureWidgetSnapshot(profile: profile)
        XCTAssertGreaterThan(second.capturedAt, first.capturedAt)
        XCTAssertLessThan(abs(second.capturedAt.timeIntervalSinceNow), 2)
        try await Task.sleep(nanoseconds: 6_500_000_000)
        XCTAssertNil(model.image, "Stop when snapshot requests cease")
        XCTAssertEqual(model.message, "Camera paused")
    }

    func testSnapshotTimerContinuesWhileStatusRequestIsStillWaiting() async throws {
        let ports = try fixturePorts()
        var profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        let fixture = profile
        var captureDates: [Date] = []
        var deps = ProgressStoreDependencies(loadProfiles: { [fixture] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { profile in try await Task.sleep(nanoseconds: 40_000_000_000); return PrinterSnapshot(profile: profile) },
            reloadWidgets: {}, verificationReports: false)
        deps.saveCameraSnapshot = { _ in captureDates.append(.now) }
        let store = ProgressStore(dependencies: deps); defer { store.stop() }
        store.start()
        let deadline = Date().addingTimeInterval(20)
        while captureDates.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(captureDates.count, 2)
        XCTAssertTrue(store.isRefreshing, "The status request is intentionally still pending")
        if captureDates.count == 2 {
            XCTAssertGreaterThanOrEqual(captureDates[1].timeIntervalSince(captureDates[0]), 4.5)
            XCTAssertLessThan(captureDates[1].timeIntervalSince(captureDates[0]), 8)
        }
        XCTAssertEqual(store.cameraSession(for: profile.id).activeViewerCount, 0)
    }

    func testSetupTestReusesAnExistingLivePreviewConnection() async throws {
        let ports = try fixturePorts()
        var profile = PrinterProfile(name: "Fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)")
        profile.camera = PrinterCameraSettings(); profile.camera?.enabled = true
        profile.camera?.streamURL = "http://127.0.0.1:\(ports["http"]!)/camera"
        let fixture = profile
        let deps = ProgressStoreDependencies(loadProfiles: { [fixture] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false)
        let store = ProgressStore(dependencies: deps); defer { store.stop() }
        let session = store.cameraSession(for: profile.id), viewer = UUID()
        session.show(viewer, profile: profile)
        defer { session.hide(viewer) }
        let deadline = Date().addingTimeInterval(5)
        while session.image == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(session.image)
        let picture = try await store.testCameraSource(for: profile.id, streamURL: profile.camera!.streamURL)
        XCTAssertNotNil(picture.image)
        XCTAssertEqual(session.activeViewerCount, 1)
        let receipts = try String(contentsOf: directory!.appendingPathComponent("receipts.jsonl"), encoding: .utf8)
        XCTAssertEqual(receipts.components(separatedBy: "http-open").count - 1, 1)
    }
    func testSetupProbeCapturesBothFormatsWithoutEnablingLiveOrWidgetPermissions() async throws {
        let ports = try fixturePorts()
        let printers = [PrinterProfile(name: "HTTP fixture", kind: .moonraker, address: "http://127.0.0.1:\(ports["http"]!)"),
                        PrinterProfile(name: "RTSPS fixture", kind: .bambu, address: "127.0.0.1", serialNumber: "FIXTURE", credential: "fixture-password")]
        var saved = printers
        var deps = ProgressStoreDependencies(loadProfiles: { printers }, loadSnapshot: { _ in nil },
            saveProfiles: { saved = $0 }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false)
        deps.cameraSource = { profile in
            if profile.camera?.streamURL.isEmpty == false { return try await PrinterCameraSource.resolve(profile) }
            return PrinterCameraSource(url: URL(string: "rtsps://127.0.0.1:\(ports["rtsp"]!)/streaming/live/1")!, headers: [:])
        }
        let store = ProgressStore(dependencies: deps); defer { store.stop() }
        let http = try await store.testCameraSource(for: printers[0].id, streamURL: "http://127.0.0.1:\(ports["http"]!)/camera")
        XCTAssertNotNil(http.image)
        let rtsp = try await store.testCameraSource(for: printers[1].id, streamURL: "")
        XCTAssertNotNil(rtsp.image)
        XCTAssertEqual(saved[1].camera?.certificateFingerprint?.count, 64, "An explicit setup test pairs the camera before sending credentials")
        for profile in store.profiles {
            XCTAssertNotEqual(profile.camera?.enabled, true)
            XCTAssertNotEqual(profile.camera?.widgetSnapshotsEnabled, true)
            XCTAssertTrue(profile.camera?.streamURL.isEmpty ?? true, "Testing does not commit a candidate source")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let receipts = try String(contentsOf: directory!.appendingPathComponent("receipts.jsonl"), encoding: .utf8)
        XCTAssertTrue(receipts.contains("http-closed")); XCTAssertTrue(receipts.contains("rtsp-closed"))
        XCTAssertTrue(store.widgetCameraDates.isEmpty)
    }

    func testCameraSetupRejectsInvalidSourceAndSaveFailureWithoutChangingSettings() throws {
        let profile = PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid")
        var saves = 0
        let deps = ProgressStoreDependencies(loadProfiles: { [profile] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in saves += 1; throw PrinterError.keychain(-25308) }, saveSnapshot: { _ in },
            deleteSnapshot: { _ in }, fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false)
        let store = ProgressStore(dependencies: deps); defer { store.stop() }
        XCTAssertThrowsError(try store.configureCamera(for: profile.id, streamURL: "rtsp://relay.invalid/live", widgetSnapshots: true))
        XCTAssertEqual(saves, 0)
        XCTAssertThrowsError(try store.configureCamera(for: profile.id, streamURL: "http://relay.invalid/camera.mjpg", widgetSnapshots: true))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertTrue(store.widgetCameraDates.isEmpty)
    }
    private var server: Process?
    private var directory: URL?
    private func fixturePorts() throws -> [String:Int] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetCamera-\(UUID())")
        self.directory = directory
        let script = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/camera_server.py")
        let server = Process(); self.server = server
        server.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        server.arguments = ["python3",script.path,"--directory",directory.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.standardError
        try server.run()
        let ready = directory.appendingPathComponent("ready.json"), deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath:ready.path),server.isRunning,Date()<deadline { Thread.sleep(forTimeInterval:0.03) }
        return try JSONDecoder().decode([String:Int].self,from:Data(contentsOf:ready))
    }
    override func tearDown() {
        if let server,server.isRunning { server.terminate(); server.waitUntilExit() }
        if let directory { try? FileManager.default.removeItem(at:directory) }
        super.tearDown()
    }
    private func image(width: Int = 1920,height: Int = 1080) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red:0.08,green:0.22,blue:0.36,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.setFillColor(CGColor(red:0.3,green:0.8,blue:0.65,alpha:1)); context.fill(CGRect(x:width/4,y:height/4,width:width/2,height:height/2))
        return try XCTUnwrap(context.makeImage())
    }
    func testThumbnailBoundsRotationAndCaptureDateRoundTrip() throws {
        let date = Date(timeIntervalSince1970:1234), generation = UUID()
        let photo = try WidgetCameraSnapshot.capture(image(),printerID:UUID(),capturedAt:date,generation:generation,rotation:90,flipHorizontal:true)
        XCTAssertLessThanOrEqual(photo.jpeg.count,128*1024)
        XCTAssertEqual(photo.image?.width,360); XCTAssertEqual(photo.image?.height,640)
        let roundTrip = try JSONDecoder().decode(WidgetCameraSnapshot.self,from:JSONEncoder().encode(photo))
        XCTAssertEqual(roundTrip,photo); XCTAssertEqual(roundTrip.capturedAt,date)
    }
    func testOptInCapturesBothProtocolsWithVideoOffAndOptOutDeletesImages() async throws {
        let ports = try fixturePorts()
        let http = ports["http"]!,rtsp = ports["rtsp"]!
        let printers = [PrinterProfile(name:"HTTP fixture",kind:.moonraker,address:"http://127.0.0.1:\(http)"),
            PrinterProfile(name:"RTSPS fixture",kind:.bambu,address:"127.0.0.1",serialNumber:"FIXTURE",credential:"fixture-password")]
        var saved: [UUID:WidgetCameraSnapshot] = [:], count = 0
        var deps = ProgressStoreDependencies(loadProfiles:{printers},loadSnapshot:{_ in nil},saveProfiles:{_ in},saveSnapshot:{_ in},
            deleteSnapshot:{_ in},fetch:{PrinterSnapshot(profile:$0)},reloadWidgets:{},autoStart:false,verificationReports:false)
        deps.cameraSource = { profile in
            if profile.kind == .bambu { return PrinterCameraSource(url:URL(string:"rtsps://127.0.0.1:\(rtsp)/streaming/live/1")!,headers:[:]) }
            return try await PrinterCameraSource.resolve(profile)
        }
        deps.saveCameraSnapshot = { saved[$0.printerID]=$0; count += 1 }
        deps.deleteCameraSnapshot = { saved[$0]=nil }
        let store = ProgressStore(dependencies:deps); defer {store.stop()}
        for printer in printers { store.setWidgetSnapshotsEnabled(true,for:printer.id) }
        let deadline = Date().addingTimeInterval(7)
        while saved.count<2,Date()<deadline { try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertEqual(saved.count,2)
        for printer in printers {
            XCTAssertEqual(store.profiles.first(where:{$0.id==printer.id})?.camera?.enabled,false)
            if printer.kind == .bambu {
                XCTAssertEqual(store.profiles.first(where:{$0.id==printer.id})?.camera?.certificateFingerprint?.count,64)
            }
            let photo = try XCTUnwrap(saved[printer.id])
            XCTAssertEqual(photo.image?.width,160); XCTAssertEqual(photo.image?.height,90)
            XCTAssertLessThan(abs(photo.capturedAt.timeIntervalSinceNow),7)
            XCTAssertEqual(photo.generation,store.profiles.first(where:{$0.id==printer.id})?.camera?.widgetSnapshotGeneration)
        }
        await store.refresh()
        XCTAssertEqual(count,2,"Status refresh must not recapture sooner than five seconds")
        let frameCounts = printers.map { store.cameraSession(for:$0.id).receivedFrameCount }
        XCTAssertTrue(frameCounts.allSatisfy {$0 > 0})
        XCTAssertTrue(printers.allSatisfy {store.cameraSession(for:$0.id).activeViewerCount == 0})
        for printer in printers { store.setWidgetSnapshotsEnabled(false,for:printer.id) }
        XCTAssertTrue(saved.isEmpty); XCTAssertTrue(store.widgetCameraDates.isEmpty)
        let stoppedCounts = printers.map { store.cameraSession(for:$0.id).receivedFrameCount }
        try await Task.sleep(nanoseconds:250_000_000)
        XCTAssertEqual(printers.map {store.cameraSession(for:$0.id).receivedFrameCount},stoppedCounts,"Opt-out must stop warmed connections immediately")
        let receipts = try String(contentsOf:directory!.appendingPathComponent("receipts.jsonl"),encoding:.utf8)
        XCTAssertTrue(receipts.contains("http-closed")); XCTAssertTrue(receipts.contains("rtsp-closed"))
    }
    func testFailedCapturePreservesOriginalPictureAndDate() async throws {
        var profile = PrinterProfile(name:"Fixture",kind:.moonraker,address:"http://printer.invalid")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        let fixture = profile, oldDate = Date(timeIntervalSince1970:1000)
        let old = try WidgetCameraSnapshot.capture(image(),printerID:fixture.id,capturedAt:oldDate)
        var saved = old
        var deps = ProgressStoreDependencies(loadProfiles:{[fixture]},loadSnapshot:{_ in nil},saveProfiles:{_ in},saveSnapshot:{_ in},
            deleteSnapshot:{_ in},fetch:{PrinterSnapshot(profile:$0)},reloadWidgets:{},autoStart:false,verificationReports:false)
        deps.loadCameraSnapshot = {_ in old}; deps.saveCameraSnapshot = {saved=$0}
        deps.cameraSource = {_ in throw PrinterCameraError.unavailable}
        let store = ProgressStore(dependencies:deps); defer {store.stop()}
        await store.refresh()
        let deadline=Date().addingTimeInterval(2)
        while store.widgetCameraMessages[fixture.id]?.hasPrefix("Snapshot unavailable") != true,Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertEqual(saved,old); XCTAssertEqual(store.widgetCameraDates[fixture.id],oldDate)
        XCTAssertTrue(store.widgetCameraMessages[fixture.id]?.hasPrefix("Snapshot unavailable") == true)
    }
    func testPermissionSaveFailureDoesNotStartCamera() async {
        let profile = PrinterProfile(name:"Fixture",kind:.moonraker,address:"http://printer.invalid")
        var deps = ProgressStoreDependencies(loadProfiles:{[profile]},loadSnapshot:{_ in nil},saveProfiles:{_ in throw PrinterError.keychain(-25308)},
            saveSnapshot:{_ in},deleteSnapshot:{_ in},fetch:{PrinterSnapshot(profile:$0)},reloadWidgets:{},autoStart:false,verificationReports:false)
        deps.cameraSource = {_ in XCTFail("Camera started without saved permission"); throw CancellationError()}
        let store = ProgressStore(dependencies:deps); defer {store.stop()}
        store.setWidgetSnapshotsEnabled(true,for:profile.id)
        XCTAssertNil(store.profiles[0].camera); XCTAssertNotNil(store.errorMessage)
    }
    func testWidgetOnlyLoadsOptedInImagesAndRejectsPicturesFromOldConnections() throws {
        var enabled = PrinterProfile(name:"Allowed",kind:.moonraker,address:"http://allowed.invalid")
        enabled.camera = PrinterCameraSettings(); enabled.camera?.widgetSnapshotsEnabled = true
        enabled.camera?.widgetSnapshotGeneration = UUID()
        let disabled = PrinterProfile(name:"Disabled",kind:.moonraker,address:"http://disabled.invalid")
        let old = try WidgetCameraSnapshot.capture(image(),printerID:enabled.id,capturedAt:.now,generation:UUID())
        var loads: [UUID] = []
        var entry=ProgressEntry(date:.now,snapshots:[PrinterSnapshot(profile:enabled),PrinterSnapshot(profile:disabled)])
        WidgetData.addCameraSnapshots(to:&entry,family:.systemExtraLarge,loadProfiles:{[enabled,disabled]},loadImage:{loads.append($0);return old})
        XCTAssertEqual(loads,[enabled.id]); XCTAssertEqual(entry.cameraAllowedIDs,[enabled.id]); XCTAssertTrue(entry.cameraSnapshots.isEmpty)
        let current = try WidgetCameraSnapshot.capture(image(),printerID:enabled.id,capturedAt:.now,generation:enabled.camera?.widgetSnapshotGeneration)
        WidgetData.addCameraSnapshots(to:&entry,family:.systemLarge,loadProfiles:{[enabled]},loadImage:{_ in current})
        XCTAssertEqual(entry.cameraSnapshots[enabled.id],current)
        var small=ProgressEntry(date:.now,snapshots:entry.snapshots)
        WidgetData.addCameraSnapshots(to:&small,family:.systemSmall,loadProfiles:{XCTFail("Small widget loaded camera settings");return []},loadImage:{_ in XCTFail();return nil})
        XCTAssertTrue(small.cameraSnapshots.isEmpty)
    }
    func testLargeAndExtraLargePhotoLayoutsWithStaleAndMissingImages() throws {
        let first = PrinterProfile(name:"Workshop",kind:.bambu,address:"printer.invalid",serialNumber:"FIXTURE",credential:"fictional")
        let second = PrinterProfile(name:"Studio",kind:.moonraker,address:"http://studio.invalid")
        let date = Date().addingTimeInterval(-7200)
        let photos = [first.id:try WidgetCameraSnapshot.capture(image(),printerID:first.id,capturedAt:date),
                      second.id:try WidgetCameraSnapshot.capture(image(),printerID:second.id,capturedAt:date)]
        let readings = [PrinterSnapshot(profile:first,state:.printing,progress:0.64,jobName:"Desk planter",remainingSeconds:2400,
            nozzleTemperature:220,bedTemperature:60,chamberTemperature:35),
            PrinterSnapshot(profile:second,state:.paused,progress:0.28,jobName:"Cable organizer",remainingSeconds:5600,nozzleTemperature:210,bedTemperature:60)]
        let controls = [first.id:try WidgetControlContext(profile:first,snapshot:readings[0]),second.id:try WidgetControlContext(profile:second,snapshot:readings[1])]
        let output=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/WidgetCameraLayout.noindex")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for dark in [false,true] {
            for (family,size,name) in [(WidgetFamily.systemLarge,NSSize(width:360,height:360),"large"),(.systemExtraLarge,NSSize(width:715,height:360),"xl")] {
                let entry=ProgressEntry(date:.now,snapshots:readings,controls:controls,cameraSnapshots:photos,cameraAllowedIDs:Set(photos.keys))
                try render(ProgressWidgetView(entry:entry,familyOverride:family),size:size,dark:dark,file:output.appendingPathComponent("\(name)-\(dark ? "dark":"light").png"))
            }
        }
        let empty=ProgressEntry(date:.now,snapshots:readings,cameraAllowedIDs:[first.id])
        try render(ProgressWidgetView(entry:empty,familyOverride:.systemExtraLarge),size:NSSize(width:715,height:360),dark:false,file:output.appendingPathComponent("xl-missing.png"))
    }
    func testGalleryPreviewsIncludeCameraIllustrationsForLargeAndXL() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/CameraLayout.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (family, size, name) in [(WidgetFamily.systemLarge, NSSize(width: 360, height: 360), "gallery-large"),
                                    (.systemExtraLarge, NSSize(width: 715, height: 360), "gallery-xl")] {
            let entry = WidgetData.previewEntry(family: family)
            XCTAssertTrue(entry.isGalleryPreview)
            XCTAssertEqual(entry.cameraAllowedIDs, Set(entry.snapshots.map(\.id)))
            XCTAssertTrue(entry.cameraSnapshots.isEmpty, "Gallery artwork must not use private camera snapshots")
            try render(ProgressWidgetView(entry: entry, familyOverride: family), size: size, dark: false,
                       file: output.appendingPathComponent("\(name).png"))
        }
        XCTAssertTrue(WidgetData.previewEntry(family: .systemMedium).cameraAllowedIDs.isEmpty)
    }

    private func render<V:View>(_ view:V,size:NSSize,dark:Bool,file:URL) throws {
        let rect=NSRect(origin:.zero,size:size), window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height).background(dark ? Color.black:Color.white).environment(\.colorScheme,dark ? .dark:.light))
        window.contentView=host; defer {window.close()}; host.frame=rect
        for _ in 0..<3 {host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.03))}
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:rect));host.cacheDisplay(in:rect,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:file)
    }
}
