import SwiftUI

/// Step-by-step permission wizard shown in the popover before the recorder.
/// Screen Recording is required; Camera and Microphone are optional.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppState

    private var permissions: PermissionsManager { app.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

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
                app.preferences.onboardingDone = true
            } label: {
                Text(permissions.canRecordScreen ? "Start Using Cue" : "Grant Screen Recording to continue")
            }
            .buttonStyle(.prominentGlass(tint: permissions.canRecordScreen ? Theme.accent : Theme.secondaryText))
            .disabled(!permissions.canRecordScreen)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: Theme.popoverWidth)
        .background(VisualEffectBlur(material: .popover, blendingMode: .behindWindow))
        .task {
            permissions.refresh()
            await permissions.verifyScreenRecording()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark()
            VStack(alignment: .leading, spacing: 1) {
                Text("Welcome to Cue").font(.cueTitle)
                Text("Grant a few permissions to start.")
                    .font(.cueCaption).foregroundStyle(Theme.secondaryText)
            }
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
