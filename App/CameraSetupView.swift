import SwiftUI

struct CameraSetupRequest: Identifiable {
    let id: UUID
    var fromWidget = false

    func initialWidgetSnapshots(for profile: PrinterProfile) -> Bool {
        fromWidget || profile.camera?.widgetSnapshotsEnabled == true
    }
}

struct CameraSetupView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.dismiss) private var dismiss
    let profile: PrinterProfile
    @State private var custom: Bool
    @State private var address: String
    @State private var widgetSnapshots: Bool
    @State private var testing = false
    @State private var picture: WidgetCameraSnapshot?
    @State private var testedAddress: String?
    @State private var error: String?
    @State private var probe: Task<Void, Never>?
    @State private var testGeneration = UUID()
    @State private var discoveredCameraID: String?
    @State private var testedCameraID: String?
    @State private var discovering = false
    @State private var discoveryFinished = false
    @State private var cameraChoices: [PrinterCameraChoice] = []
    @State private var discovery: Task<Void, Never>?
    @State private var discoveryGeneration = UUID()

    init(profile: PrinterProfile, fromWidget: Bool = false) {
        self.profile = profile
        _discoveredCameraID = State(initialValue: profile.camera?.discoveredCameraID)
        _custom = State(initialValue: profile.camera?.streamURL.isEmpty == false)
        _address = State(initialValue: profile.camera?.streamURL ?? "")
        _widgetSnapshots = State(initialValue: CameraSetupRequest(id: profile.id, fromWidget: fromWidget)
            .initialWidgetSnapshots(for: profile))
    }
    private var selectedAddress: String { custom ? address.trimmingCharacters(in: .whitespacesAndNewlines) : "" }
    private var selectedCameraID: String? { custom ? nil : discoveredCameraID }
    private var canSave: Bool { picture != nil && testedAddress == selectedAddress && testedCameraID == selectedCameraID && !testing && !discovering }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Camera for \(profile.name)").font(.title2.weight(.semibold))
                    Text("Choose a connection, test the picture, then save it for the app and menu bar.")
                        .foregroundStyle(.secondary)
                    discoveryOptions
                    Picker("Camera connection", selection: Binding(get: { custom }, set: { resetTest(); custom = $0 })) {
                        Text("Direct local camera").tag(false)
                        Text("Bridge or custom URL").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("camera-setup-method")
                    if custom { bridgeOptions } else { directOptions }
                    if let image = picture?.image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxHeight: 190).clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Camera test picture received")
                        Label("Picture received. Camera is ready.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                            .accessibilityIdentifier("camera-setup-success")
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("camera-setup-error") }
                    Button { testCamera() } label: {
                        HStack { if testing { ProgressView().controlSize(.small) }; Text(testing ? "Testing camera…" : "Test camera") }
                    }.disabled(testing || discovering).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("camera-setup-test")
                    Toggle("Use snapshots in large and XL widgets", isOn: $widgetSnapshots)
                        .accessibilityIdentifier("camera-setup-snapshots")
                    Text("Camera snapshots use the interval chosen in Settings while monitoring. Widgets show the saved picture’s age; macOS and iOS decide when widgets redraw.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
            .navigationTitle("Set up camera")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { probe?.cancel(); discovery?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save camera") {
                        do { try store.configureCamera(for: profile.id, streamURL: selectedAddress, widgetSnapshots: widgetSnapshots, discoveredCameraID: selectedCameraID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!canSave).accessibilityIdentifier("camera-setup-save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 710)
        #endif
        .onDisappear { probe?.cancel(); discovery?.cancel() }
    }

    private var discoveryOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                resetTest(); discovery?.cancel(); discovering = true; discoveryFinished = false; cameraChoices = []
                let generation = UUID(); discoveryGeneration = generation
                discovery = Task { @MainActor in
                    defer { if discoveryGeneration == generation { discovering = false } }
                    do {
                        let choices = try await store.discoverCameras(for: profile.id)
                        try Task.checkCancellation()
                        guard discoveryGeneration == generation else { return }
                        cameraChoices = choices; discoveryFinished = true
                    } catch is CancellationError { }
                    catch { if discoveryGeneration == generation { self.error = error.localizedDescription } }
                }
            } label: {
                HStack {
                    if discovering { ProgressView().controlSize(.small) }
                    Label(discovering ? "Discovering cameras…" : "Discover cameras", systemImage: "magnifyingglass")
                }
            }
            .buttonStyle(.bordered).disabled(discovering || testing)
            .accessibilityIdentifier("camera-setup-discover")
            Text("Finds camera connections reported by this printer and includes your saved custom connection. Select a result to test its picture. Bridges must already be configured.")
                .font(.caption).foregroundStyle(.secondary)
            if discoveryFinished {
                if cameraChoices.isEmpty {
                    Text("No camera connections found. Check the printer’s camera settings, or enter a custom camera URL below.")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("camera-discovery-empty")
                } else {
                    Text("\(cameraChoices.count) camera connection\(cameraChoices.count == 1 ? "" : "s") found")
                        .font(.callout.weight(.semibold)).accessibilityIdentifier("camera-discovery-results")
                    ForEach(cameraChoices) { choice in
                        Button {
                            resetTest()
                            custom = !choice.streamURL.isEmpty
                            if custom { address = choice.streamURL }
                            discoveredCameraID = choice.discoveredCameraID
                            testCamera()
                        } label: {
                            Label(choice.name, systemImage: "camera").lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered).disabled(testing || discovering)
                        .accessibilityLabel("Use camera \(choice.name)")
                    }
                }
            }
        }
    }

    private func testCamera() {
        resetTest(); testing = true
        let source = selectedAddress, cameraID = selectedCameraID
        let generation = UUID(); testGeneration = generation
        probe = Task { @MainActor in
            defer { if testGeneration == generation { testing = false } }
            do {
                if custom && source.isEmpty { throw PrinterCameraError.unsupported }
                let photo = try await store.testCameraSource(for: profile.id, streamURL: source, discoveredCameraID: cameraID)
                try Task.checkCancellation()
                guard testGeneration == generation else { return }
                picture = photo; testedAddress = source; testedCameraID = cameraID
            } catch is CancellationError { }
            catch { if testGeneration == generation { self.error = error.localizedDescription } }
        }
    }

    private var directOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect directly to the printer", systemImage: "wifi").font(.headline)
            if profile.kind == .bambu {
                Text("On the printer, open its network settings and find LAN Mode Liveview or LAN Only Liveview. This enables the built-in local camera feed.")
                Text("Read the warning on your printer before enabling it. If it says cloud or Bambu Handy camera viewing will be disabled and you want to keep that access, choose the bridge option instead.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Print Progress uses your saved LAN access code and checks the camera certificate before signing in. It does not change printer settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if profile.kind == .moonraker {
                Text("The camera is discovered from Moonraker, including the camera address and port it reports. Test the picture below, then save. Use Bridge or custom URL if your camera is not listed in Moonraker.")
            } else {
                Text("For this printer type, choose Bridge or custom URL and enter an HTTP or HTTPS MJPEG stream address.")
            }
        }
    }
    private var bridgeOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Use a separately configured video source", systemImage: "network").font(.headline)
            if profile.kind == .bambu {
                Text("1. In Bambu Studio, open Device and start this printer’s camera.\n2. Open Camera settings and enable Go Live. Install Bambu’s camera tools if prompted.\n3. Run a separate relay that converts Studio’s exported video to an HTTP/HTTPS MJPEG stream, then enter its address below.")
                Text("Keep Studio signed in and the relay’s host available. An on-demand relay can pause video processing between viewers and snapshots. This option leaves printer settings alone. Check Bambu Handy camera access after connecting; simultaneous viewing depends on the source and firmware.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Custom Camera URL", text: Binding(get: { address }, set: { resetTest(); address = $0 }), prompt: Text("http://localhost:8898/camera.mjpg"))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("camera-setup-url")
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                #endif
            Text("Use an HTTP or HTTPS MJPEG stream, rather than a webpage, SDP file, or RTSP URL. A localhost address works only when the relay runs on this device. Print Progress does not install or control bridge software.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func resetTest() {
        testGeneration = UUID()
        probe?.cancel(); probe = nil; testing = false; picture = nil; testedAddress = nil; testedCameraID = nil; error = nil
    }
}
