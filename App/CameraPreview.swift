import SwiftUI

@MainActor
final class CameraPreviewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var connectingSnapshot: WidgetCameraSnapshot?
    @Published private(set) var message = "Connecting to camera…"
    @Published private(set) var failed = false
    @Published private(set) var failure: PrinterCameraError?
    @Published private(set) var hasReceivedFrame = false
    @Published private(set) var source: PrinterCameraSource?
    private let onCertificate: @MainActor (String) throws -> Void
    private let resolve: @Sendable (PrinterProfile) async throws -> PrinterCameraSource
    private let loadSnapshot: (UUID) throws -> WidgetCameraSnapshot?
    private var jpeg: MJPEGCameraStream?
    private var bambu: BambuCameraStream?
    private var task: Task<Void, Never>?
    private var idleStopTask: Task<Void, Never>?
    private var viewers: Set<UUID> = []
    private var snapshotViewers: Set<UUID> = []
    var hasVisibleViewer: Bool { !viewers.subtracting(snapshotViewers).isEmpty }
    private var profile: PrinterProfile?
    private var generation = UUID()
    private var lastFrame = Date.distantPast
    #if DEBUG
    private(set) var receivedFrameCount = 0
    var activeViewerCount: Int { viewers.count }
    var lastReceivedFrameAt: Date? { lastFrame == .distantPast ? nil : lastFrame }
    #endif

    init(resolve: @escaping @Sendable (PrinterProfile) async throws -> PrinterCameraSource = { try await PrinterCameraSource.resolve($0) },
         loadSnapshot: @escaping (UUID) throws -> WidgetCameraSnapshot? = { _ in nil },
         onCertificate: @escaping @MainActor (String) throws -> Void) {
        self.resolve = resolve; self.loadSnapshot = loadSnapshot; self.onCertificate = onCertificate
    }
    func show(_ viewer: UUID, profile: PrinterProfile) {
        idleStopTask?.cancel(); idleStopTask = nil
        viewers.insert(viewer)
        let changed = self.profile.map {
            $0.address != profile.address || $0.credential != profile.credential || $0.camera?.streamURL != profile.camera?.streamURL
                || ($0.camera?.certificateFingerprint != nil && $0.camera?.certificateFingerprint != profile.camera?.certificateFingerprint)
        } ?? true
        self.profile = profile
        if profile.camera?.widgetSnapshotsEnabled != true || connectingSnapshot?.generation != profile.camera?.widgetSnapshotGeneration {
            connectingSnapshot = nil
        }
        if changed { hasReceivedFrame = false }
        if changed || task == nil || failed { connect(profile) }
    }
    func hide(_ viewer: UUID, keepWarm: Bool = false) {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        if keepWarm && !failed {
            idleStopTask?.cancel()
            idleStopTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 6_000_000_000) }
                catch { return }
                guard let self, self.viewers.isEmpty else { return }
                self.stop()
            }
        } else { stop() }
    }
    func releaseSnapshotWarmth() {
        if viewers.isEmpty { stop() }
    }
    func retry() { if let profile, !viewers.isEmpty { connect(profile) } }
    func captureWidgetSnapshot(profile: PrinterProfile, capturedAfter: Date? = nil) async throws -> WidgetCameraSnapshot {
        let viewer = UUID()
        snapshotViewers.insert(viewer)
        show(viewer, profile: profile)
        defer {
            hide(viewer, keepWarm: profile.camera?.widgetSnapshotsEnabled == true)
            snapshotViewers.remove(viewer)
        }
        let minimumFrameDate = capturedAfter ?? Date().addingTimeInterval(-2)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try Task.checkCancellation()
            if let image, let source, lastFrame >= minimumFrameDate {
                return try WidgetCameraSnapshot.capture(image, printerID: profile.id, capturedAt: lastFrame,
                    generation: profile.camera?.widgetSnapshotGeneration,
                    rotation: source.rotation, flipHorizontal: source.flipHorizontal, flipVertical: source.flipVertical)
            }
            if failed { throw failure ?? PrinterCameraError.disconnected }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PrinterCameraError.timeout
    }
    func stop() {
        idleStopTask?.cancel(); idleStopTask = nil
        generation = UUID()
        task?.cancel(); task = nil
        jpeg?.stop(); jpeg = nil; bambu?.stop(); bambu = nil
        image = nil; source = nil; connectingSnapshot = nil
        message = "Camera paused"; failed = false; failure = nil
    }
    private func connect(_ profile: PrinterProfile) {
        stop()
        message = "Connecting to camera…"
        if profile.camera?.widgetSnapshotsEnabled == true,
           let snapshot = try? loadSnapshot(profile.id), snapshot.printerID == profile.id,
           snapshot.generation == profile.camera?.widgetSnapshotGeneration, snapshot.image != nil {
            connectingSnapshot = snapshot
        }
        let generation = generation
        let resolve = resolve
        task = Task { [weak self] in
            do {
                let source = try await resolve(profile)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.source = source
                let frame: @Sendable (CGImage) -> Void = { [weak self] image in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        // Preview-sized UI needs at most ten images a second.
                        guard Date().timeIntervalSince(self.lastFrame) >= 0.1 else { return }
                        #if DEBUG
                        self.receivedFrameCount += 1
                        #endif
                        self.lastFrame = .now; self.image = image; self.connectingSnapshot = nil
                        self.failed = false; self.hasReceivedFrame = true; self.message = "Live camera"
                    }
                }
                let error: @Sendable (Error) -> Void = { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.image = nil; self.connectingSnapshot = nil; self.failed = true
                        self.failure = (error as? PrinterCameraError) ?? .disconnected
                        // URLSession errors can embed a private endpoint. Show a
                        // fixed camera message instead of logging/displaying URLs.
                        self.message = (error as? PrinterCameraError)?.localizedDescription ?? "Camera disconnected. Check the connection and try again."
                    }
                }
                if source.url.scheme == "rtsps" {
                    let stream = BambuCameraStream(profile: profile, source: source,
                        onCertificate: { [weak self] fingerprint in
                            guard let self else { throw CancellationError() }
                            try await self.acceptCertificate(fingerprint, generation: generation)
                        }, onFrame: frame, onError: error)
                    self.bambu = stream; stream.start()
                } else {
                    let stream = MJPEGCameraStream(onFrame: frame, onError: error)
                    self.jpeg = stream; stream.start(source)
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == generation else { return }
                self.connectingSnapshot = nil; self.failed = true; self.failure = (error as? PrinterCameraError) ?? .unavailable
                self.message = (error as? PrinterCameraError)?.localizedDescription ?? "Camera unavailable. Check the connection or set a camera stream address in Edit connection."
            }
        }
    }
    private func acceptCertificate(_ fingerprint: String, generation: UUID) throws {
        guard self.generation == generation else { throw CancellationError() }
        try onCertificate(fingerprint)
    }
    deinit { idleStopTask?.cancel(); task?.cancel(); jpeg?.stop(); bambu?.stop() }
}

struct PrinterCameraControls: View {
    @EnvironmentObject private var store: ProgressStore
    let profile: PrinterProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { profile.camera?.enabled == true }, set: { store.setCameraEnabled($0, for: profile.id) })) {
                Label("Show camera", systemImage: "video")
            }
            .toggleStyle(.switch).font(.caption)
            .accessibilityIdentifier("camera-toggle-\(profile.name)")
            Toggle(isOn: Binding(get: { profile.camera?.widgetSnapshotsEnabled == true },
                                set: { store.setWidgetSnapshotsEnabled($0, for: profile.id) })) {
                Label("Camera snapshots in widgets", systemImage: "photo")
            }
            .toggleStyle(.switch).font(.caption)
            .accessibilityIdentifier("widget-camera-toggle-\(profile.name)")
            #if os(macOS)
            Button("Open camera monitor", systemImage: "macwindow") {
                store.setCameraEnabled(true, for: profile.id)
                PrintProgressAppDelegate.prepareToOpenWindow()
                openWindow(id: "camera-monitor", value: profile.id)
            }
            .font(.caption).buttonStyle(.bordered)
            #endif
            Button("Set up camera", systemImage: "video") { openSetup() }
                .font(.caption).buttonStyle(.bordered)
                .accessibilityIdentifier("camera-setup-\(profile.name)")
            if profile.camera?.enabled == true {
                CameraPreview(profile: profile, model: store.cameraSession(for: profile.id), setup: openSetup)
            }
            if profile.camera?.widgetSnapshotsEnabled == true {
                Text("Large and XL widgets use saved pictures. Camera snapshots use the interval chosen in Settings while monitoring. Widget updates are scheduled by the system.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let capturedAt = store.widgetCameraDates[profile.id] {
                    Text("Photo age \(capturedAt, style: .timer)").monospacedDigit().contentTransition(.identity)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let message = store.widgetCameraMessages[profile.id] {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    private func openSetup() {
        store.cameraSetup = CameraSetupRequest(id: profile.id)
        #if os(macOS)
        PrintProgressAppDelegate.prepareToOpenWindow()
        openWindow(id: "printers")
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
}

struct CameraPreview: View {
    let profile: PrinterProfile
    @ObservedObject var model: CameraPreviewModel
    var setup: (() -> Void)? = nil
    @State private var viewer = UUID()
    @State private var visible = false
    @State private var windowVisible = false
    @State private var withinViewport = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.black
                if let image = model.image, let source = model.source {
                    GeometryReader { geometry in
                        let quarterTurn = source.rotation == 90 || source.rotation == 270
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit()
                            .frame(width: quarterTurn ? geometry.size.height : geometry.size.width,
                                   height: quarterTurn ? geometry.size.width : geometry.size.height)
                            .rotationEffect(.degrees(Double(source.rotation)))
                            .scaleEffect(x: source.flipHorizontal ? -1 : 1, y: source.flipVertical ? -1 : 1)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                } else {
                    if !model.failed, let image = model.connectingSnapshot?.image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .overlay(Color.black.opacity(0.35))
                    }
                    VStack(spacing: 8) {
                        if model.failed { Image(systemName: "video.slash").font(.title2) }
                        else { ProgressView().tint(.white).environment(\.colorScheme, .dark) }
                        Text(model.failed && profile.kind == .bambu && profile.camera?.streamURL.isEmpty != false
                             ? "Choose how to connect this printer’s camera." : model.message)
                            .font(.caption).multilineTextAlignment(.center)
                        if !model.failed, let snapshot = model.connectingSnapshot {
                            Text("Last photo age · \(snapshot.capturedAt, style: .timer)").monospacedDigit().contentTransition(.identity)
                                .font(.caption2).multilineTextAlignment(.center)
                        }
                        if model.failed {
                            if let setup {
                                Button("Set up camera", action: setup).buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("camera-preview-setup-\(profile.name)")
                            }
                            if model.hasReceivedFrame { Button("Retry") { model.retry() }.buttonStyle(.bordered) }
                        }
                    }
                    .foregroundStyle(.white).padding(12)
                    .background(.black.opacity(model.connectingSnapshot == nil ? 0 : 0.65), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.message)
            .accessibilityIdentifier("camera-preview-\(profile.name)")
            .onGeometryChange(for: Bool.self) { proxy in
                guard let bounds = proxy.bounds(of: .scrollView) else { return true }
                let frame = proxy.frame(in: .scrollView)
                let intersection = frame.intersection(CGRect(origin: .zero, size: bounds.size))
                return frame.height > 0 && !intersection.isNull && intersection.height / frame.height > 0.05
            } action: { isVisible in
                withinViewport = isVisible; updateVisibility()
            }
            if model.image != nil {
                Label("Live camera", systemImage: "circle.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .background(CameraWindowVisibility { isVisible in
            windowVisible = isVisible; updateVisibility()
        })
        #else
        .onAppear { windowVisible = scenePhase == .active; updateVisibility() }
        .onChange(of: scenePhase) { _, phase in
            windowVisible = phase == .active; updateVisibility()
        }
        #endif
        .onChange(of: profile) { _, profile in if visible { model.show(viewer, profile: profile) } }
        .onDisappear { visible = false; model.hide(viewer) }
    }
    private func updateVisibility() {
        let next = windowVisible && withinViewport
        guard next != visible else { return }
        visible = next
        if next { model.show(viewer, profile: profile) } else { model.hide(viewer) }
    }
}

#if os(macOS)
/// MenuBarExtra can keep its SwiftUI tree alive after dismissal. Observe the
/// actual window, rather than trusting onDisappear to release the camera.
private struct CameraWindowVisibility: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Observer { Observer(changed: changed) }
    func updateNSView(_ view: Observer, context: Context) { view.changed = changed; view.report() }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.shutdown() }
    final class Observer: NSView {
        var changed: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        private var lastVisible: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            if let window {
                observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main) { [weak self] _ in self?.report() })
                var ancestor = superview
                while let view = ancestor {
                    if let clip = view as? NSClipView {
                        clip.postsBoundsChangedNotifications = true
                        observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                            object: clip, queue: .main) { [weak self] _ in self?.report() })
                    }
                    ancestor = view.superview
                }
            }
            report()
        }
        override func layout() { super.layout(); report() }
        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); report() }
        func report() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty } ?? false
            guard lastVisible != visible else { return }
            lastVisible = visible
            // Avoid mutating SwiftUI's state during its update pass.
            DispatchQueue.main.async { [weak self] in self?.changed(visible) }
        }
        func shutdown() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            let changed = changed
            DispatchQueue.main.async { changed(false) }
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}
#endif
