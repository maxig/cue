import SwiftUI

/// Settings shown as a screen *inside* the popover (pushed over the recorder),
/// with a back button — not a separate window.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var updater: UpdaterController
    @StateObject private var cloudflareSetup = CloudflareProvisioner()
    @State private var cloudflareToken = ""
    @State private var selectedZoneID = ""
    @State private var subdomainLabel = "cue"
    var onBack: () -> Void = {}

    private var prefs: Preferences { app.preferences }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    formatCard
                    recordingCard
                    cameraCard
                    backgroundCard
                    sharingCard
                    generalCard
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, 16)
            }
            .frame(maxHeight: 540)
        }
        .frame(width: Theme.popoverWidth)
        .background(VisualEffectBlur(material: .popover, blendingMode: .behindWindow))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 30, height: 30)
                    .liquidGlass(in: Circle())
            }
            .buttonStyle(.plain)
            Text("Settings").font(.cueTitle)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, 4)
    }

    // MARK: Cards

    private var formatCard: some View {
        Card("Format") {
            StackedRow("Aspect ratio") {
                Picker("", selection: Binding(get: { prefs.aspectMode }, set: { prefs.aspectMode = $0 })) {
                    ForEach(AspectRatioMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Caption(prefs.aspectMode == .sixteenNine
                    ? "Every recording is a clean 16:9 frame. Screens that aren't 16:9 are fit onto the canvas — never cropped or black-barred."
                    : "Recordings keep the captured screen's own proportions.")
        }
    }

    private var recordingCard: some View {
        Card("Recording") {
            LabeledRow("Countdown") {
                Picker("", selection: $app.config.countdownSeconds) {
                    Text("Off").tag(0); Text("3s").tag(3); Text("5s").tag(5); Text("10s").tag(10)
                }
                .labelsHidden().fixedSize()
            }
            Divider().opacity(0.5)
            LabeledRow("Frame rate") {
                Picker("", selection: Binding(get: { prefs.captureFPS }, set: { prefs.captureFPS = $0 })) {
                    Text("30 fps").tag(30); Text("60 fps").tag(60)
                }
                .labelsHidden().fixedSize()
            }
            Caption(prefs.captureFPS == 60
                    ? "Smoother motion for fast-moving content; larger files."
                    : "Standard 30 fps — smaller files, ideal for most screen recordings.")
            Divider().opacity(0.5)
            ToggleRow("Cinematic pointer effects", isOn: Binding(
                get: { prefs.cinematicEffectsEnabled },
                set: { prefs.cinematicEffectsEnabled = $0 }))
            Caption("Smooths the cursor, adds a click ripple, and gently zooms toward clicks in display recordings.")
            Divider().opacity(0.5)
            ToggleRow("Capture system audio",
                      isOn: $app.config.captureSystemAudio)
        }
    }

    private var cameraCard: some View {
        Card("Camera") {
            StackedRow("Bubble shape") {
                Picker("", selection: Binding(get: { prefs.cameraBubbleShape }, set: { prefs.cameraBubbleShape = $0 })) {
                    ForEach(CameraBubbleShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Divider().opacity(0.5)
            ToggleRow("Mirror (selfie view)", isOn: Binding(
                get: { prefs.cameraMirrored }, set: { prefs.cameraMirrored = $0 }))
            Divider().opacity(0.5)
            LabeledRow("Background") {
                Picker("", selection: Binding(
                    get: { prefs.cameraBackground },
                    set: { prefs.cameraBackground = $0; app.setCameraBackgroundLive($0) })) {
                    ForEach(CameraBackground.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Caption("Replaces what’s behind you in the bubble. Transparent lets the screen show through; Blur, Gradient and Color stay opaque.")
            Divider().opacity(0.5)
            ToggleRow("Center Stage", isOn: Binding(
                get: { prefs.centerStageEnabled },
                set: { prefs.centerStageEnabled = $0; app.setCenterStageLive($0) }))
                .disabled(!app.selectedCameraSupportsCenterStage)
                .opacity(app.selectedCameraSupportsCenterStage ? 1 : 0.5)
            Caption(app.selectedCameraSupportsCenterStage
                    ? "Automatically keeps you framed as you move. Works with Continuity Camera and supported webcams."
                    : "The selected camera doesn’t support Center Stage.")
            Divider().opacity(0.5)
            LabeledRow("Corner") {
                Picker("", selection: Binding(get: { prefs.cameraCorner }, set: { prefs.cameraCorner = $0 })) {
                    ForEach(CameraCorner.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Divider().opacity(0.5)
            StackedRow("Size") {
                Slider(value: Binding(get: { prefs.cameraBubbleSize }, set: { prefs.cameraBubbleSize = $0 }),
                       in: 120...320)
            }
            Divider().opacity(0.5)
            ToggleRow("Show while recording", isOn: Binding(
                get: { prefs.showCameraBubble }, set: { prefs.showCameraBubble = $0 }))
        }
    }

    private var backgroundCard: some View {
        Card("Background") {
            StackedRow("Style") {
                CanvasBackgroundPicker(selection: Binding(
                    get: { prefs.canvasBackground },
                    set: { prefs.canvasBackground = $0 }
                ))
            }
            Divider().opacity(0.5)
            StackedRow("Padding") {
                Picker("", selection: paddingPercentBinding) {
                    Text("0").tag(0)
                    Text("2%").tag(2)
                    Text("4%").tag(4)
                    Text("6%").tag(6)
                    Text("8%").tag(8)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(prefs.canvasBackground == .none)
                .opacity(prefs.canvasBackground == .none ? 0.4 : 1)
            }
            Caption("Frames the screen on the backdrop with rounded corners and a soft shadow. 0 makes the screen fill the frame.")
        }
    }

    private var sharingCard: some View {
        let settings = app.uploadSettings
        return VStack(alignment: .leading, spacing: 18) {
            Card("Sharing") {
                LabeledRow("Upload to") {
                    Picker("", selection: Binding(get: { settings.backend }, set: { settings.backend = $0 })) {
                        ForEach(UploadBackend.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if settings.backend == .localStub {
                    Caption("Recordings stay on this Mac with a placeholder link. Choose “Cue server” to upload and get a working web link.")
                }
            }

            // One-click Cloudflare setup: paste a single token, Cue provisions
            // storage, database, and the share server by itself.
            if settings.backend == .cueServer {
                cloudflareCard
                    .onAppear { cloudflareSetup.bootstrap(settings: settings) }
            }

            // The web player / share server (the Cloudflare Worker, or local Node).
            if settings.backend == .cueServer {
                Card("Server") {
                    Field("Worker URL", \.backendBaseURL, "https://cue.example.com")
                    Field("Owner token", \.ownerToken, "", secure: true)
                    Caption("Authenticates uploads, share management, and Library AI without a web login. Use the same value as the Worker’s OWNER_TOKEN secret; it stays in the macOS Keychain.")
                }
            }

            // Where the video files are stored (S3-compatible: Cloudflare R2, MinIO…).
            if settings.backend == .minio || settings.backend == .cueServer {
                Card("Storage bucket") {
                    Field("Endpoint", \.endpoint, "https://<account>.r2.cloudflarestorage.com")
                    Field("Region", \.region, "auto")
                    Field("Bucket", \.bucket, "cue")
                    Field("Access key", \.accessKey, "")
                    Field("Secret key", \.secretKey, "", secure: true)
                    Caption("For Cloudflare R2, Region must be “auto”. The secret key is stored in the macOS Keychain.")
                }
            }
        }
    }

    // MARK: Cloudflare one-click setup

    @ViewBuilder
    private var cloudflareCard: some View {
        Card("Cloudflare — automatic setup") {
            switch cloudflareSetup.phase {
            case .idle:
                Caption("Cue can set up free Cloudflare sharing for you: storage, database, and your own share server — no manual configuration.")
                RowButton("Set up automatically…", system: "wand.and.stars") {
                    NSWorkspace.shared.open(CloudflareProvisioner.tokenCreationURL)
                    cloudflareSetup.beginTokenEntry()
                }
                Divider().opacity(0.5)
                RowButton("Create a free Cloudflare account…", system: "person.badge.plus") {
                    NSWorkspace.shared.open(CloudflareProvisioner.signupURL)
                }
                Caption("No account yet? Create one first, then come back and choose “Set up automatically”.")

            case .enteringToken:
                Caption("Your browser opened a Cloudflare page with a ready-made token. Click “Continue to summary”, then “Create Token”, copy the token, and paste it here.")
                SecureField("", text: $cloudflareToken, prompt: Text("Paste the token"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .padding(.vertical, 4)
                HStack(spacing: 10) {
                    Button("Connect") { cloudflareSetup.connect(token: cloudflareToken) }
                        .disabled(cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Cancel") {
                        cloudflareToken = ""
                        cloudflareSetup.cancel()
                    }
                }
                .controlSize(.small)
                .padding(.vertical, 9)
                Divider().opacity(0.5)
                RowButton("Open the token page again", system: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(CloudflareProvisioner.tokenCreationURL)
                }

            case .selectingAccount(let accounts):
                Caption("The token can reach more than one Cloudflare account. Pick where Cue should set up sharing.")
                ForEach(accounts) { account in
                    RowButton(account.name, system: "building.2") {
                        cloudflareSetup.continueWith(account: account)
                    }
                }
                Divider().opacity(0.5)
                HStack {
                    Spacer()
                    Button("Cancel") { cloudflareSetup.cancel() }.controlSize(.small)
                }
                .padding(.vertical, 9)

            case .running(let current):
                ForEach(CloudflareProvisioner.Step.allCases, id: \.rawValue) { step in
                    HStack(spacing: 9) {
                        if step < current {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                        } else if step == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        Text(step.title)
                            .font(.cueRowTitle)
                            .foregroundStyle(step <= current ? Theme.primaryText : Theme.tertiaryText)
                        Spacer()
                    }
                    .frame(minHeight: 26)
                }
                Caption("Setting things up on your Cloudflare account. This usually takes under a minute.")

            case .failed(let step, let message, let help):
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(step.title).font(.cueRowTitle).foregroundStyle(Theme.primaryText)
                    Spacer()
                }
                .padding(.vertical, 8)
                Caption(message)
                if case .enableR2(let accountId) = help {
                    RowButton("Enable R2 storage in Cloudflare…", system: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(CloudflareProvisioner.r2PlanURL(accountId: accountId))
                    }
                }
                HStack(spacing: 10) {
                    Button("Try Again") { cloudflareSetup.retry() }
                    Spacer()
                    Button("Cancel") { cloudflareSetup.cancel() }
                }
                .controlSize(.small)
                .padding(.vertical, 9)

            case .connected(let workerURL):
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                    Text("Connected").font(.cueRowTitle).foregroundStyle(Theme.primaryText)
                    Spacer()
                }
                .padding(.vertical, 8)
                Caption("Your recordings share at \(workerURL). The fields below were filled in automatically — you normally don't need to touch them.")
                Divider().opacity(0.5)
                domainSection
                Divider().opacity(0.5)
                RowButton("Run setup again…", system: "arrow.clockwise") {
                    cloudflareSetup.reprovision()
                }
                Caption("Re-checks everything and publishes this app version's share server — useful after an update.")
                Divider().opacity(0.5)
                RowButton("Forget Cloudflare token", system: "xmark.circle") {
                    cloudflareToken = ""
                    cloudflareSetup.forgetToken()
                }
                Caption("Forgetting the token only stops automatic setup — sharing keeps working with the settings below.")
            }
        }
    }

    /// Inside the connected card: move the share link onto one of the
    /// account's own domains, entirely from within Settings.
    @ViewBuilder
    private var domainSection: some View {
        switch cloudflareSetup.domainPhase {
        case .idle:
            RowButton("Use your own domain…", system: "globe") {
                cloudflareSetup.beginDomainSelection()
            }

        case .loadingZones:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Looking up your domains…").font(.cueRowTitle).foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(.vertical, 10)

        case .choosing(let zones):
            Caption("Pick a domain and a subdomain for your share links. Cloudflare creates the address and certificate automatically.")
            Picker("", selection: $selectedZoneID) {
                ForEach(zones) { zone in Text(zone.name).tag(zone.id) }
            }
            .labelsHidden()
            .onAppear { if selectedZoneID.isEmpty { selectedZoneID = zones.first?.id ?? "" } }
            HStack(spacing: 6) {
                TextField("", text: $subdomainLabel, prompt: Text("cue"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 90)
                Text("." + (zones.first(where: { $0.id == selectedZoneID })?.name ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 4)
            HStack(spacing: 10) {
                Button("Connect domain") {
                    if let zone = zones.first(where: { $0.id == selectedZoneID }) {
                        cloudflareSetup.attachDomain(zone: zone, subdomain: subdomainLabel)
                    }
                }
                .disabled(selectedZoneID.isEmpty || subdomainLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") { cloudflareSetup.cancelDomainSelection() }
            }
            .controlSize(.small)
            .padding(.vertical, 9)

        case .attaching(let hostname):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Setting up \(hostname)…").font(.cueRowTitle).foregroundStyle(Theme.primaryText)
                Spacer()
            }
            .padding(.vertical, 10)
            Caption("Creating the address and its certificate. This can take a few minutes on a brand-new subdomain.")

        case .failed(let message):
            Caption(message)
            HStack(spacing: 10) {
                Button("Try Again") { cloudflareSetup.beginDomainSelection() }
                Spacer()
                Button("Cancel") { cloudflareSetup.cancelDomainSelection() }
            }
            .controlSize(.small)
            .padding(.vertical, 9)
        }
    }

    private var generalCard: some View {
        Card("General") {
            RowButton("Open recordings folder", system: "folder") {
                NSWorkspace.shared.open(app.store.baseURL)
            }
            Divider().opacity(0.5)
            RowButton("Check for Updates…", system: "arrow.triangle.2.circlepath") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            Divider().opacity(0.5)
            RowButton("Quit Cue", system: "power", destructive: true) {
                NSApp.terminate(nil)
            }
            Divider().opacity(0.5)
            Caption(version)
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Cue \(v) (\(build))"
    }

    // MARK: Bindings

    /// Bridges the Double `screenPadding` to the 5-position percent picker.
    private var paddingPercentBinding: Binding<Int> {
        Binding(
            get: {
                let p = Int((prefs.screenPadding * 100).rounded())
                return [0, 2, 4, 6, 8].min(by: { abs($0 - p) < abs($1 - p) }) ?? 0
            },
            set: { prefs.screenPadding = Double($0) / 100.0 }
        )
    }

    // MARK: Field helper

    @ViewBuilder
    private func Field(_ label: String,
                       _ keyPath: ReferenceWritableKeyPath<UploadSettings, String>,
                       _ prompt: String, secure: Bool = false) -> some View {
        let settings = app.uploadSettings
        let binding = Binding(get: { settings[keyPath: keyPath] },
                              set: { settings[keyPath: keyPath] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.cueCaption).foregroundStyle(Theme.secondaryText)
            Group {
                if secure { SecureField("", text: binding) }
                else { TextField("", text: binding, prompt: Text(prompt)) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Building blocks

private struct CanvasBackgroundPicker: View {
    @Binding var selection: CanvasBackground

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )

    private var presets: [CanvasBackground] {
        CanvasBackground.allCases.filter { !$0.isArtwork }
    }

    private var artwork: [CanvasBackground] {
        CanvasBackground.allCases.filter(\.isArtwork)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            backgroundGrid(presets)

            Text("ARTWORK")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.tertiaryText)

            backgroundGrid(artwork)
        }
    }

    private func backgroundGrid(_ backgrounds: [CanvasBackground]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(backgrounds) { background in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = background
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            CanvasBackgroundPreview(background: background)
                                .frame(height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(selection == background ? Theme.accent : Color.white.opacity(0.12),
                                                lineWidth: selection == background ? 2 : 0.5)
                                }

                            if selection == background {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(width: 14, height: 14)
                                    .background(Circle().fill(Theme.accent))
                                    .padding(4)
                            }
                        }

                        Text(background.title)
                            .font(.system(size: 9.5, weight: selection == background ? .semibold : .medium))
                            .foregroundStyle(selection == background ? Theme.primaryText : Theme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(background.title)
                .accessibilityValue(selection == background ? "Selected" : "")
            }
        }
    }
}

private struct CanvasBackgroundPreview: View {
    let background: CanvasBackground

    var body: some View {
        Group {
            if let assetName = background.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
            } else if let stops = background.gradient {
                LinearGradient(
                    colors: [color(stops.top), color(stops.bottom)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                ZStack {
                    Color.black.opacity(0.16)
                    Image(systemName: "rectangle.slash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func color(_ rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 13)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }
}

/// Label on the left, control on the right.
private struct LabeledRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.cueRowTitle).foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 10)
    }
}

/// Label above, full-width control below (for segmented pickers / sliders).
private struct StackedRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.cueRowTitle).foregroundStyle(Theme.primaryText)
            control
        }
        .padding(.vertical, 10)
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }
    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(.cueRowTitle).foregroundStyle(Theme.primaryText)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 8)
    }
}

private struct RowButton: View {
    let label: String
    let system: String
    var destructive = false
    let action: () -> Void
    init(_ label: String, system: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.system = system; self.destructive = destructive; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: system).frame(width: 16)
                Text(label).font(.cueRowTitle)
                Spacer()
            }
            .foregroundStyle(destructive ? Color.red : Theme.primaryText)
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.cueCaption)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
    }
}
