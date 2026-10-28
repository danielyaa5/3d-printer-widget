import SwiftUI

struct AddPrinterView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.dismiss) private var dismiss
    var existing: PrinterProfile?
    @State private var name = ""
    @State private var kind: PrinterKind = .moonraker
    @State private var address = ""
    @State private var serialNumber = ""
    @State private var credential = ""
    @State private var username = ""
    @State private var passwordAuthentication = false
    @State private var isChecking = false
    @State private var error: String?
    @State private var resetCertificate = false
    @State private var cameraURL = ""
    @State private var checkTask: Task<Void, Never>?

    init(existing: PrinterProfile? = nil, initialKind: PrinterKind = .moonraker) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: existing?.kind ?? initialKind)
        _address = State(initialValue: existing?.address ?? "")
        _serialNumber = State(initialValue: existing?.serialNumber ?? "")
        _credential = State(initialValue: existing?.credential ?? "")
        _username = State(initialValue: existing?.username ?? "")
        _cameraURL = State(initialValue: existing?.camera?.streamURL ?? "")
        _passwordAuthentication = State(initialValue: existing?.username != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("My printer"))
                        .accessibilityIdentifier("printer-name")
                    Picker("Printer type", selection: $kind) {
                        ForEach(PrinterKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .disabled(existing != nil)
                }
                Section {
                    TextField(kind.addressLabel, text: $address, prompt: Text(kind.addressExample))
                        .accessibilityIdentifier("printer-address")
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(kind == .bambu ? .asciiCapable : .URL)
                        #endif
                    if kind == .bambu {
                        TextField("Serial number", text: $serialNumber)
                            .accessibilityIdentifier("printer-serial")
                            #if os(iOS)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            #endif
                        SecureField("LAN access code", text: $credential)
                            .accessibilityIdentifier("printer-credential")
                    } else if kind == .prusaLink {
                        Picker("Authentication", selection: $passwordAuthentication) {
                            Text("API key").tag(false)
                            Text("Username and password").tag(true)
                        }
                        if passwordAuthentication {
                            TextField("Local username", text: $username)
                                .accessibilityIdentifier("printer-username")
                                #if os(iOS)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                #endif
                            SecureField("Local password", text: $credential)
                                .accessibilityIdentifier("printer-credential")
                        } else {
                            SecureField("PrusaLink API key", text: $credential)
                                .accessibilityIdentifier("printer-credential")
                        }
                    } else if kind == .duet {
                        SecureField("Machine password (optional)", text: $credential)
                            .accessibilityIdentifier("printer-credential")
                    } else if kind == .moonraker || kind == .octoPrint {
                        SecureField("API key (optional)", text: $credential)
                            .accessibilityIdentifier("printer-credential")
                    }
                } footer: {
                    Text(kind.connectionHelp)
                }
                    Section {
                        TextField("Custom Camera URL (optional)", text: $cameraURL,
                                  prompt: Text("http://camera.local/stream.mjpg"))
                            .accessibilityIdentifier("camera-stream-address")
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            #endif
                    } header: {
                        Text("Camera")
                    } footer: {
                        Text(cameraHelp)
                    }
                if kind == .bambu, existing?.certificateFingerprint != nil || existing?.camera?.certificateFingerprint != nil {
                    Section {
                        Toggle("Trust a replacement certificate", isOn: $resetCertificate)
                    } footer: {
                        Text("Use this only after verifying a firmware update or printer replacement. The new certificate will be saved after a successful connection.")
                    }
                }
                Section {
                    Label("Access codes stay in Keychain.", systemImage: "lock.shield")
                    Label("Connecting only reads printer status.", systemImage: "eye")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .disabled(isChecking)
            .navigationTitle(existing == nil ? "Add printer" : "Edit connection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { checkTask?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        checkTask = Task { await connect() }
                    } label: {
                        if isChecking { ProgressView().controlSize(.small) }
                        else { Text("Connect") }
                    }
                    .disabled(isChecking).accessibilityIdentifier("connect-printer")
                }
            }
        }
        #if os(macOS)
        .frame(width: 490, height: (kind == .bambu || kind == .prusaLink ? 570 : 480) + 140)
        #endif
        .alert("Couldn’t connect", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onChange(of: kind) { _, _ in credential = ""; username = ""; passwordAuthentication = false; address = ""; error = nil }
        .onChange(of: passwordAuthentication) { _, _ in credential = ""; error = nil }
        .onDisappear { checkTask?.cancel() }
    }

    private var cameraHelp: String {
        let format = "Optional HTTP or HTTPS MJPEG stream, including a camera relay you set up separately. Video page links and RTSP URLs are not supported here."
        switch kind {
        case .bambu:
            return "Leave blank for the built-in local camera. It requires LAN Liveview; read the printer’s warning before enabling it. \(format)"
        case .moonraker:
            return "Leave blank to discover the camera from Moonraker. \(format)"
        default:
            return format
        }
    }

    @MainActor
    private func connect() async {
        isChecking = true; error = nil
        defer { isChecking = false }
        do {
            let sameEndpoint = existing?.address.trimmingCharacters(in: .whitespacesAndNewlines) == address.trimmingCharacters(in: .whitespacesAndNewlines)
                && existing?.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines) == serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            var profile = try PrinterProfile(id: existing?.id ?? UUID(), name: name, kind: kind, address: address,
                 serialNumber: serialNumber, credential: credential,
                 certificateFingerprint: resetCertificate || !sameEndpoint ? nil : existing?.certificateFingerprint,
                 username: kind == .prusaLink && passwordAuthentication ? username : nil).validated()
            var camera = existing?.camera ?? PrinterCameraSettings()
            camera.streamURL = cameraURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !camera.streamURL.isEmpty { _ = try PrinterCameraSource.validatedHTTPURL(camera.streamURL) }
            if resetCertificate || !sameEndpoint { camera.certificateFingerprint = nil; camera.discoveredCameraID = nil }
            profile.camera = camera
            let snapshot = try await PrinterClient.fetch(profile)
            try Task.checkCancellation()
            try store.save(profile, snapshot: snapshot)
            dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
