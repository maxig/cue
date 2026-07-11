import SwiftUI

/// Settings shown as a screen *inside* the popover (pushed over the recorder),
/// with a back button — not a separate window.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
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
            LabeledRow("Style") {
                Picker("", selection: Binding(get: { prefs.canvasBackground }, set: { prefs.canvasBackground = $0 })) {
                    ForEach(CanvasBackground.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
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
                } else {
                    Divider().opacity(0.5)
                    ToggleRow("Copy link when ready", isOn: Binding(
                        get: { prefs.instantShare }, set: { prefs.instantShare = $0 }))
                    Caption("When a recording finishes, enable its share link and copy it to the clipboard right away. Off keeps links private until you enable them.")
                }
            }

            // The web player / share server (the Cloudflare Worker, or local Node).
            if settings.backend == .cueServer {
                Card("Server") {
                    Field("Worker URL", \.backendBaseURL, "https://cue.example.com")
                    Field("Owner token (optional)", \.ownerToken, "", secure: true)
                    Caption("Locks delete / disable / upload to you. Leave blank to keep them open; if set, use the same value as the Worker’s OWNER_TOKEN secret.")
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

    private var generalCard: some View {
        Card("General") {
            RowButton("Open recordings folder", system: "folder") {
                NSWorkspace.shared.open(app.store.baseURL)
            }
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
        return "Cue \(v)"
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
