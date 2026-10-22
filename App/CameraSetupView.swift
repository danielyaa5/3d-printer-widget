import SwiftUI

struct CameraSetupRequest: Identifiable { let id: UUID }

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

    init(profile: PrinterProfile) {
        self.profile = profile
        _custom = State(initialValue: profile.camera?.streamURL.isEmpty == false)
        _address = State(initialValue: profile.camera?.streamURL ?? "")
        _widgetSnapshots = State(initialValue: profile.camera?.widgetSnapshotsEnabled == true)
    }
    private var selectedAddress: String { custom ? address.trimmingCharacters(in: .whitespacesAndNewlines) : "" }
    private var canSave: Bool { picture != nil && testedAddress == selectedAddress && !testing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Camera for \(profile.name)").font(.title2.weight(.semibold))
                    Text("Choose a connection, test the picture, then save it for the app and menu bar.")
                        .foregroundStyle(.secondary)
                    Picker("Camera connection", selection: $custom) {
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
                    Button {
                        probe?.cancel(); picture = nil; testedAddress = nil; error = nil; testing = true
                        let source = selectedAddress
                        let generation = UUID(); testGeneration = generation
                        probe = Task { @MainActor in
                            defer { if testGeneration == generation { testing = false } }
                            do {
                                if custom && source.isEmpty { throw PrinterCameraError.unsupported }
                                let photo = try await store.testCameraSource(for: profile.id, streamURL: source)
                                try Task.checkCancellation()
                                guard testGeneration == generation else { return }
                                picture = photo; testedAddress = source
                            } catch is CancellationError { }
                            catch { if testGeneration == generation { self.error = error.localizedDescription } }
                        }
                    } label: {
                        HStack { if testing { ProgressView().controlSize(.small) }; Text(testing ? "Testing camera…" : "Test camera") }
                    }.disabled(testing).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("camera-setup-test")
                    Toggle("Use snapshots in large and XL widgets", isOn: $widgetSnapshots)
                        .accessibilityIdentifier("camera-setup-snapshots")
                    Text("Print Progress requests a picture every 15 seconds while monitoring. Widgets show the saved picture’s age; macOS and iOS decide when widgets redraw.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
            .navigationTitle("Set up camera")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { probe?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save camera") {
                        do { try store.configureCamera(for: profile.id, streamURL: selectedAddress, widgetSnapshots: widgetSnapshots); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!canSave).accessibilityIdentifier("camera-setup-save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 710)
        #endif
        .onChange(of: address) { _, _ in resetTest() }
        .onChange(of: custom) { _, _ in resetTest() }
        .onDisappear { probe?.cancel() }
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
                Text("The camera is discovered from Moonraker. If its stream uses a separate address or port, choose Bridge or custom URL and enter the full MJPEG address.")
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
            TextField("Custom Camera URL", text: $address, prompt: Text("http://localhost:8898/camera.mjpg"))
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
        probe?.cancel(); probe = nil; testing = false; picture = nil; testedAddress = nil; error = nil
    }
}
