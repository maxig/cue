import SwiftUI

/// Content of the floating recorder panel. Switches between the countdown
/// pill and the live recording control bar.
struct RecordingOverlayView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            switch app.state {
            case .countdown(let n):
                CountdownPill(seconds: n)
            case .recording, .processing:
                RecordingControlBar()
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: app.state)
    }
}

private struct CountdownPill: View {
    @EnvironmentObject private var app: AppState
    let seconds: Int

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(seconds)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text("Get ready…")
                    .font(.system(size: 13, weight: .semibold))
                Text("Recording starts in \(seconds)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer(minLength: 4)

            Button {
                app.cancelCountdown()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassControl(shape: AnyShape(Circle())))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct RecordingControlBar: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                RecordingDot(size: 9, paused: app.isPaused)
                Text(statusText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(app.isPaused ? Theme.secondaryText : Theme.recording)
            }

            Text(app.elapsed.clockString)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .frame(minWidth: 50, alignment: .leading)

            Spacer(minLength: 2)

            if app.hasMicSource {
                controlButton(app.micActive ? "mic.fill" : "mic.slash.fill",
                              on: app.micActive, disabled: app.isPaused,
                              action: app.toggleMic)
            }
            if app.hasCameraSource {
                controlButton(app.cameraActive ? "video.fill" : "video.slash.fill",
                              on: app.cameraActive, disabled: app.isPaused,
                              action: app.toggleCamera)
            }
            controlButton(app.isPaused ? "play.fill" : "pause.fill",
                          on: true, disabled: false,
                          action: app.togglePause)

            stopButton
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var statusText: String {
        if app.isProcessing { return "Saving" }
        return app.isPaused ? "Paused" : "REC"
    }

    private func controlButton(_ system: String, on: Bool, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Theme.primaryText : Theme.recording)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glassControl(shape: AnyShape(Circle())))
        .disabled(disabled || app.isProcessing)
        .opacity(disabled ? 0.4 : 1)
    }

    private var stopButton: some View {
        Button {
            Task { await app.stop() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.recording))
        }
        .buttonStyle(.plain)
        .disabled(app.isProcessing)
    }
}
