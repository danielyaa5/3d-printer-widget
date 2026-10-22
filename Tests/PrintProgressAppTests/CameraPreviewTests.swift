import XCTest

@MainActor
final class CameraPreviewTests: XCTestCase {
    func testNewCaptureRetriesAfterAnUnavailableBridge() async throws {
        let profile = PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid")
        let viewer = UUID()
        // The resolver runs once for each later capture even when the live viewer remains registered.
        let counting = CountingResolver()
        let camera = CameraPreviewModel(resolve: { try await counting.resolve($0) }, onCertificate: { _ in })
        camera.show(viewer, profile: profile)
        let deadline = Date().addingTimeInterval(2)
        while !camera.failed, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(camera.failed)
        for expected in 2...3 {
            do { _ = try await camera.captureWidgetSnapshot(profile: profile); XCTFail("Unavailable source succeeded") }
            catch { XCTAssertTrue(error is PrinterCameraError) }
            let starts = await counting.starts
            XCTAssertEqual(starts, expected)
        }
        camera.hide(viewer)
    }
    private actor CountingResolver {
        var starts = 0
        func resolve(_ profile: PrinterProfile) async throws -> PrinterCameraSource {
            starts += 1
            throw PrinterCameraError.unavailable
        }
    }
    private actor Resolver {
        var starts = 0
        func resolve(_ profile: PrinterProfile) async throws -> PrinterCameraSource {
            starts += 1
            try await Task.sleep(nanoseconds:30_000_000_000)
            throw CancellationError()
        }
    }
    func testSharedPreviewKeepsConnectionUntilLastViewerClosesAndRestartsOnReopen() async throws {
        let resolver = Resolver()
        let model = CameraPreviewModel(resolve: { try await resolver.resolve($0) }, onCertificate: { _ in })
        let profile = PrinterProfile(name:"Fixture",kind:.moonraker,address:"http://printer.invalid")
        let app = UUID(), menu = UUID()
        model.show(app,profile:profile); model.show(menu,profile:profile)
        try await Task.sleep(nanoseconds:20_000_000)
        let initialStarts = await resolver.starts
        XCTAssertEqual(initialStarts,1)
        model.hide(app)
        XCTAssertEqual(model.message,"Connecting to camera…","Closing one view must not interrupt the other")
        model.hide(menu)
        XCTAssertEqual(model.message,"Camera paused")
        model.show(menu,profile:profile)
        try await Task.sleep(nanoseconds:20_000_000)
        let reopenedStarts = await resolver.starts
        XCTAssertEqual(reopenedStarts,2)
        model.hide(menu)
    }
}
