import XCTest
import SwiftUI
import AppKit

@MainActor
final class CameraLayoutTests: XCTestCase {
    func testMonochromeProgressRemainsVisibleWithoutColor() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/CameraLayout.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(VStack(spacing: 24) {
            ForEach([0.0, 0.31, 0.64, 1.0], id: \.self) { value in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Int(value * 100))%")
                    WidgetProgressBar(value: value, tint: .white)
                }
            }
        }.padding(24).foregroundStyle(.white).environment(\.colorScheme, .dark)
            .background(Color(red: 0.12, green: 0.24, blue: 0.29)), width: 450, height: 280,
            file: output.appendingPathComponent("monochrome-progress.png"))
    }
    func testConnectingOverlayShowsSavedPictureAndCaptureAge() throws {
        var profile = PrinterProfile(name: "Camera fixture", kind: .moonraker, address: "http://printer.invalid")
        profile.camera = PrinterCameraSettings(); profile.camera?.widgetSnapshotsEnabled = true
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 0.8, green: 0.65, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 70, y: 60, width: 180, height: 240))
        let photo = try WidgetCameraSnapshot.capture(XCTUnwrap(context.makeImage()), printerID: profile.id, capturedAt: Date().addingTimeInterval(-300))
        let model = CameraPreviewModel(resolve: { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError()
        }, loadSnapshot: { _ in photo }, onCertificate: { _ in })
        let viewer = UUID(); model.show(viewer, profile: profile); defer { model.hide(viewer) }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/CameraLayout.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(CameraPreview(profile: profile, model: model), width: 470, height: 280,
            file: output.appendingPathComponent("connecting-snapshot.png"))
    }
    func testCustomCameraSetupForms() throws {
        let store = ProgressStore(dependencies: .init(loadProfiles: { [] }, loadSnapshot: { _ in nil },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false))
        defer { store.stop() }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/CameraLayout.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(AddPrinterView(initialKind: .moonraker).environmentObject(store), width: 490, height: 620,
                   file: output.appendingPathComponent("add-custom-camera.png"))
        try render(AddPrinterView(existing: PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid"))
            .environmentObject(store), width: 490, height: 710, file: output.appendingPathComponent("edit-custom-camera.png"))
        let direct = PrinterProfile(name: "Fixture", kind: .bambu, address: "printer.invalid")
        try render(CameraSetupView(profile: direct).environmentObject(store), width: 540, height: 710,
                   file: output.appendingPathComponent("setup-direct.png"))
        try render(CameraSetupView(profile: direct, fromWidget: true).environmentObject(store), width: 540, height: 710,
                   file: output.appendingPathComponent("setup-from-widget.png"))
        var bridge = direct; bridge.camera = PrinterCameraSettings(); bridge.camera?.streamURL = "http://localhost:8898/camera.mjpg"
        try render(CameraSetupView(profile: bridge).environmentObject(store), width: 540, height: 710,
                   file: output.appendingPathComponent("setup-bridge.png"))
    }
    func testExpandedCameraFitsDropdownAndAppCard() throws {
        var profile = PrinterProfile(name: "Camera fixture", kind: .moonraker, address: "http://printer.invalid")
        profile.camera = PrinterCameraSettings(); profile.camera?.enabled = true
        profile.camera?.widgetSnapshotsEnabled = true
        let fixture = profile
        let store = ProgressStore(dependencies: .init(loadProfiles: { [fixture] }, loadSnapshot: { _ in PrinterSnapshot(profile: fixture) },
            saveProfiles: { _ in }, saveSnapshot: { _ in }, deleteSnapshot: { _ in },
            fetch: { PrinterSnapshot(profile: $0) }, reloadWidgets: {}, autoStart: false, verificationReports: false))
        defer { store.stop() }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/CameraLayout.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(MenuBarView().environmentObject(store), width: 520, height: 800, file: output.appendingPathComponent("menu-expanded.png"))
        try render(PrinterCard(snapshot: PrinterSnapshot(profile: fixture)).environment(\.cameraProfile, fixture).environmentObject(store),
            width: 422, height: 460, file: output.appendingPathComponent("card-expanded.png"))
    }
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, file: URL) throws {
        let bounds = NSRect(x:0,y:0,width:width,height:height)
        let window = NSWindow(contentRect:bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:view.frame(width:width,height:height).background(Color.white))
        window.contentView = host
        defer { window.close() }
        host.frame = bounds
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.03)) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:bounds))
        host.cacheDisplay(in:bounds,to:bitmap)
        let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        XCTAssertGreaterThan(png.count,1000)
        try png.write(to:file)
    }
}
