import SwiftUI

/// First-run flow shown in the popover: intro → permissions → email → sharing.
/// The current step is stored on AppState so the popover closing mid-flow
/// (granting permissions or fetching the Cloudflare token both leave the app)
/// resumes where the user left off.
enum OnboardingStep {
    case intro
    case permissions
    case email
    case sharing
}

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState

    private var permissions: PermissionsManager { app.permissions }

    var body: some View {
        ScrollView {
            Group {
                switch app.onboardingStep {
                case .intro: introStep
                case .permissions: permissionsStep
                case .email:
                    EmailStep(settings: app.uploadSettings,
                              back: { app.onboardingStep = .permissions },
                              next: { app.onboardingStep = .sharing })
                case .sharing: sharingStep
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: Theme.popoverWidth)
        .frame(maxHeight: 560)
        .background(VisualEffectBlur(material: .popover, blendingMode: .behindWindow))
        .task {
            permissions.refresh()
            await permissions.verifyScreenRecording()
            // A veteran whose permission was revoked shouldn't retake the tour.
            if app.preferences.onboardingDone { app.onboardingStep = .permissions }
        }
    }

    // MARK: Intro

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandMark()
                Text("Welcome to Cue").font(.cueTitle)
            }
            Text("Record your screen and camera, then share a link the moment you stop.")
                .font(.cueCaption).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                IntroPoint(icon: "rectangle.inset.filled.badge.record",
                           text: "Crisp screen recordings with your camera bubble, mic, and cinematic pointer effects.")
                IntroPoint(icon: "link",
                           text: "Every recording becomes a web link with a player, comments, and reactions.")
                IntroPoint(icon: "lock.shield",
                           text: "Runs on your own storage — you keep the keys; nothing passes through anyone else.")
            }
            .padding(.vertical, 4)

            Button {
                app.onboardingStep = .permissions
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.prominentGlass(tint: Theme.accent))
        }
    }

    // MARK: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Permissions").font(.cueTitle)
                Text("Grant a few permissions to record.")
                    .font(.cueCaption).foregroundStyle(Theme.secondaryText)
            }

            VStack(spacing: 8) {
                PermissionStep(
                    icon: "rectangle.inset.filled.badge.record",
                    title: "Screen Recording",
                    subtitle: "Required to capture your screen.",
                    required: true,
                    status: permissions.screenRecording,
                    grant: { permissions.requestScreenRecording() },
                    openSettings: { permissions.openScreenRecordingSettings() }
                )
                PermissionStep(
                    icon: "video.fill",
                    title: "Camera",
                    subtitle: "For your webcam bubble. Optional.",
                    required: false,
                    status: permissions.camera,
                    grant: { Task { await permissions.requestCamera() } },
                    openSettings: { permissions.openCameraSettings() }
                )
                PermissionStep(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "For your narration. Optional.",
                    required: false,
                    status: permissions.microphone,
                    grant: { Task { await permissions.requestMicrophone() } },
                    openSettings: { permissions.openMicrophoneSettings() }
                )
            }

            if permissions.screenRecording == .denied {
                relaunchHint
            }

            Button {
                app.onboardingStep = .email
            } label: {
                Text(permissions.canRecordScreen ? "Continue" : "Grant Screen Recording to continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prominentGlass(tint: permissions.canRecordScreen ? Theme.accent : Theme.secondaryText))
            .disabled(!permissions.canRecordScreen)
        }
    }

    private var relaunchHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enabled it in System Settings? macOS applies Screen Recording only after a relaunch.")
                .font(.cueCaption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Relaunch Cue") { app.relaunch() }
                .buttonStyle(.glassControl)
                .font(.cueCaption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                     tint: Theme.warning.opacity(0.5))
    }

    // MARK: Sharing

    private var sharingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Share from anywhere",
                       subtitle: "Cue can set up free cloud sharing on your own Cloudflare account — storage, database, and a private share server, all automatic.",
                       back: { app.onboardingStep = .email })

            CloudflareSetupSection(provisioner: app.cloudflareSetup, settings: app.uploadSettings)

            SharingFooter(provisioner: app.cloudflareSetup) {
                app.preferences.onboardingDone = true
            }
        }
    }
}

// MARK: - Pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String
    var back: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 22, height: 22)
                            .liquidGlass(in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Text(title).font(.cueTitle)
            }
            Text(subtitle)
                .font(.cueCaption).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IntroPoint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text(text)
                .font(.cueCaption).foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Email page: feeds the web-library lock (a one-time code emailed on sign-in).
private struct EmailStep: View {
    let settings: UploadSettings
    var back: () -> Void
    var next: () -> Void
    @State private var email: String

    init(settings: UploadSettings, back: @escaping () -> Void, next: @escaping () -> Void) {
        self.settings = settings
        self.back = back
        self.next = next
        _email = State(initialValue: settings.ownerEmail)
    }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksValid: Bool {
        trimmed.isEmpty || (trimmed.contains("@") && trimmed.contains(".") && !trimmed.hasSuffix("."))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Your email",
                       subtitle: "Locks your online video library: signing in on the web emails you a one-time code — no password to remember. Optional; add or change it later in Settings.",
                       back: back)

            TextField("", text: $email, prompt: Text("you@example.com"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            Button {
                settings.ownerEmail = trimmed
                next()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.prominentGlass(tint: Theme.accent))
            .disabled(!looksValid)

            Button("Skip for now") { next() }
                .buttonStyle(.plain)
                .font(.cueCaption).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Finish control for the sharing page: prominent once connected, quiet skip
/// otherwise.
private struct SharingFooter: View {
    @ObservedObject var provisioner: CloudflareProvisioner
    var finish: () -> Void

    var body: some View {
        if case .connected = provisioner.phase {
            Button {
                finish()
            } label: {
                Text("Start Using Cue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.prominentGlass(tint: Theme.accent))
        } else {
            Button("Skip for now — set up anytime in Settings") { finish() }
                .buttonStyle(.plain)
                .font(.cueCaption).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct PermissionStep: View {
    let icon: String
    let title: String
    let subtitle: String
    let required: Bool
    let status: PermissionsManager.Status
    let grant: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(status.isGranted ? Theme.teal : Theme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).font(.cueRowTitle)
                    if required {
                        Text("REQUIRED")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    }
                }
                Text(subtitle).font(.cueCaption).foregroundStyle(Theme.secondaryText)
            }

            Spacer(minLength: 6)

            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .font(.system(size: 16))
        case .notDetermined:
            Button("Grant", action: grant)
                .buttonStyle(.glassControl)
                .font(.cueCaption)
        case .denied:
            Button("Settings", action: openSettings)
                .buttonStyle(.glassControl)
                .font(.cueCaption)
        }
    }
}
