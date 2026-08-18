import SwiftUI

/// The menubar popover — Cue's primary surface. Mirrors the Cap/Loom reference
/// layout: brand header, source segmented control, source picker, camera and
/// microphone rows, and a prominent record button, all in Liquid Glass.
struct RecorderPopoverView: View {
    @EnvironmentObject private var app: AppState

    private var needsOnboarding: Bool {
        !app.permissions.canRecordScreen || !app.preferences.onboardingDone
    }

    var body: some View {
        Group {
            if needsOnboarding {
                OnboardingView()
            } else if app.showSettings {
                SettingsView(onBack: { app.showSettings = false })
            } else {
                recorder
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { app.errorMessage != nil },
                                    set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var recorder: some View {
        GlassContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                if app.lastShareURL != nil, app.justFinished != nil {
                    ShareResultCard()
                }

                sourceSection
                cameraSection
                microphoneSection
                creativeSection
                recordButton
                footer
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: Theme.popoverWidth)
        .background(VisualEffectBlur(material: .popover, blendingMode: .behindWindow))
        // Preview lifecycle (refresh + camera bubble + region rectangle) is driven
        // from StatusItemController's NSPopoverDelegate, not SwiftUI `.task`/
        // `.onDisappear` — those fire unreliably inside a persistent popover host.
        .onChange(of: app.config.mode) { _, newMode in
            if newMode == .window {
                Task { await app.devices.refreshScreenContent() }
            }
            app.persistDeviceSelections()
            app.liveSelectionChanged()
        }
        .onChange(of: app.config.window?.id) { _, _ in app.liveSelectionChanged() }
        .onChange(of: app.config.display?.id) { _, _ in app.liveSelectionChanged() }
        .onChange(of: app.config.camera?.id) { _, _ in
            app.persistDeviceSelections()
            app.liveSelectionChanged()
        }
        .onChange(of: app.config.microphone?.id) { _, _ in app.persistDeviceSelections() }
        .onChange(of: app.config.cameraEnabled) { _, _ in app.liveSelectionChanged() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark()
            Text("Cue")
                .font(.cueTitle)
            Spacer()
            iconButton("gearshape") { app.showSettings = true }
            iconButton("rectangle.stack") { app.openLibrary() }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glassControl(shape: AnyShape(Circle())))
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSegmentedControl(
                segments: [
                    Segment(CaptureMode.screen, "Screen", systemImage: "display"),
                    Segment(CaptureMode.window, "Window", systemImage: "macwindow"),
                    Segment(CaptureMode.cameraOnly, "Camera", systemImage: "web.camera")
                ],
                selection: $app.config.mode
            )

            switch app.config.mode {
            case .screen, .area:
                RowMenu(
                    systemImage: "display",
                    title: app.config.display?.name ?? "No display",
                    options: app.devices.displays.map { ($0.id.description, $0.name) },
                    onSelect: { id in
                        app.config.display = app.devices.displays.first { $0.id.description == id }
                    }
                )
            case .window:
                WindowPickerList()
            case .cameraOnly:
                EmptyView()
            }
        }
    }

    // MARK: Camera

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Camera")
            ControlRow(
                systemImage: cameraOn ? "video.fill" : "video.slash",
                iconColor: cameraOn ? Theme.accent : Theme.secondaryText
            ) {
                DeviceMenu(
                    title: app.config.camera?.name ?? "No Camera",
                    options: [("__none__", "No Camera")] + app.devices.cameras.map { ($0.id, $0.name) },
                    onSelect: { id in
                        if id == "__none__" {
                            app.config.camera = .none("No Camera")
                            app.config.cameraEnabled = false
                        } else {
                            app.config.camera = app.devices.cameras.first { $0.id == id }
                            app.config.cameraEnabled = true
                        }
                    }
                )
            } trailing: {
                pillToggle(isOn: cameraOn, enabled: hasCamera) {
                    app.config.cameraEnabled.toggle()
                }
            }
        }
    }

    private var cameraOn: Bool { app.config.cameraEnabled && hasCamera }
    private var hasCamera: Bool { app.config.camera?.isNone == false }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Microphone")
            ControlRow(
                systemImage: micOn ? "mic.fill" : "mic.slash",
                iconColor: micOn ? Theme.accent : Theme.secondaryText
            ) {
                DeviceMenu(
                    title: app.config.microphone?.name ?? "No Audio",
                    options: [("__none__", "No Audio")] + app.devices.microphones.map { ($0.id, $0.name) },
                    onSelect: { id in
                        if id == "__none__" {
                            app.config.microphone = .none("No Audio")
                            app.config.microphoneEnabled = false
                        } else {
                            app.config.microphone = app.devices.microphones.first { $0.id == id }
                            app.config.microphoneEnabled = true
                        }
                    }
                )
            } trailing: {
                pillToggle(isOn: micOn, enabled: hasMic) {
                    app.config.microphoneEnabled.toggle()
                }
            }
        }
    }

    private var micOn: Bool { app.config.microphoneEnabled && hasMic }
    private var hasMic: Bool { app.config.microphone?.isNone == false }

    // MARK: Creative Mode

    private var creativeOn: Bool { app.preferences.creativeModeEnabled }

    private var scriptWordCount: Int {
        app.preferences.scriptDraft.split(whereSeparator: \.isWhitespace).count
    }

    private var creativeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Vertical video")
            ControlRow(
                systemImage: creativeOn ? "sparkles" : "rectangle.portrait",
                iconColor: creativeOn ? Theme.accent : Theme.secondaryText
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Creative Mode")
                        .font(.cueRowTitle)
                    Text(creativeOn ? app.preferences.creativeLayout.title : "For Shorts, TikTok, Reels")
                        .font(.cueCaption)
                        .foregroundStyle(Theme.secondaryText)
                }
            } trailing: {
                pillToggle(isOn: creativeOn, enabled: true) {
                    app.preferences.creativeModeEnabled.toggle()
                }
            }

            if creativeOn {
                RowMenu(
                    systemImage: app.preferences.creativeLayout.systemImage,
                    title: app.preferences.creativeLayout.title,
                    options: CreativeLayout.allCases.map { ($0.rawValue, $0.title) },
                    onSelect: { id in
                        if let layout = CreativeLayout(rawValue: id) {
                            app.preferences.creativeLayout = layout
                        }
                    }
                )

                ControlRow(
                    systemImage: "captions.bubble",
                    iconColor: app.preferences.captionsEnabled ? Theme.accent : Theme.secondaryText
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Captions").font(.cueRowTitle)
                        Text(app.preferences.captionsEnabled
                             ? app.preferences.captionStyle.title
                             : "For watching without sound")
                            .font(.cueCaption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                } trailing: {
                    pillToggle(isOn: app.preferences.captionsEnabled, enabled: true) {
                        app.preferences.captionsEnabled.toggle()
                        // Ask for permission now, while nothing is recording —
                        // never in the middle of a take.
                        if app.preferences.captionsEnabled,
                           app.permissions.speechRecognition == .notDetermined {
                            Task { await app.permissions.requestSpeechRecognition() }
                        }
                    }
                }

                Button {
                    app.teleprompter.show(appState: app, mode: .editing)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.aligncenter")
                            .font(.system(size: 12, weight: .medium))
                        Text(app.preferences.scriptDraft.isEmpty ? "Write a script…" : "Edit script")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if scriptWordCount > 0 {
                            Text(scriptWordCount == 1 ? "1 word" : "\(scriptWordCount) words")
                                .font(.cueCaption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.glassControl)
            }
        }
    }

    private func pillToggle(isOn: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OnOffPill(isOn: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: Record button

    private var recordButton: some View {
        Button {
            app.toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: app.isBusy ? "stop.fill" : "record.circle")
                Text(recordButtonTitle)
            }
        }
        .buttonStyle(.prominentGlass(tint: app.isBusy ? Theme.recording : Theme.accent))
        .padding(.top, 2)
    }

    private var recordButtonTitle: String {
        switch app.state {
        case .idle: return "Start Recording"
        case .countdown: return "Cancel"
        case .recording: return "Stop Recording"
        // Writing captions takes a while — say what's happening rather than
        // leaving "Saving…" on screen for minutes.
        case .processing: return app.captionGenerator.phase.title ?? "Saving…"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Open Library") { app.openLibrary() }
                .buttonStyle(.plain)
                .font(.cueCaption)
                .foregroundStyle(Theme.accent)
            Spacer()
            Text("\(app.store.recordings.count) recordings")
                .font(.cueCaption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.top, 2)
    }
}

// MARK: - Brand mark

struct BrandMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Theme.accent, Theme.teal],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
        }
        .frame(width: 26, height: 26)
        .shadow(color: Theme.accent.opacity(0.4), radius: 4, y: 1)
    }
}

// MARK: - Row pickers

/// A glass row whose center is a borderless menu (used for display/window).
private struct RowMenu: View {
    let systemImage: String
    let title: String
    let options: [(String, String)]
    let onSelect: (String) -> Void

    var body: some View {
        ControlRow(systemImage: systemImage) {
            DeviceMenu(title: title, options: options, onSelect: onSelect)
        } trailing: {
            EmptyView()
        }
    }
}

/// Borderless menu styled to read as inline text + chevron.
struct DeviceMenu: View {
    let title: String
    let options: [(String, String)]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            if options.isEmpty {
                Text("None available")
            }
            ForEach(options, id: \.0) { option in
                Button(option.1) { onSelect(option.0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.cueRowTitle)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - Window picker (thumbnails)

private struct WindowPickerList: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let windows = app.devices.windows
        if windows.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .foregroundStyle(Theme.secondaryText)
                Text("No windows found")
                    .font(.cueCaption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        } else {
            // A ScrollView in a self-sizing popover has no definite height to
            // expand into, so it collapses to zero and the list is invisible.
            // Give it a concrete height (capped) and lazy-build the rows.
            let rowHeight: CGFloat = 74
            let listHeight = min(CGFloat(windows.count) * (rowHeight + 6), 232)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(windows) { window in
                        WindowRow(window: window,
                                  isSelected: app.config.window?.id == window.id) {
                            app.config.window = window
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: listHeight)
        }
    }
}

private struct WindowRow: View {
    let window: WindowOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !window.title.isEmpty {
                        Text(window.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous),
                         tint: isSelected ? Theme.accent.opacity(0.5) : nil)
        }
        .buttonStyle(.plain)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.25))
            if let image = window.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "macwindow")
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .frame(width: 104, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

// MARK: - Inline notices

private struct PermissionNotice: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.warning)
                Text("Screen Recording is off")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Enable Cue in Privacy & Security to record your screen.")
                .font(.cueCaption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Settings") { app.permissions.openScreenRecordingSettings() }
                    .buttonStyle(.glassControl)
                    .font(.cueCaption)
                Button("Request") { app.permissions.requestScreenRecording() }
                    .buttonStyle(.glassControl)
                    .font(.cueCaption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                     tint: Theme.warning.opacity(0.6))
    }
}

private struct ShareResultCard: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text("Link copied to clipboard")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    app.justFinished = nil
                    app.lastShareURL = nil
                } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if let url = app.lastShareURL {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Button("Copy Link") {
                    if let url = app.lastShareURL { app.copyLink(url.absoluteString) }
                }
                .buttonStyle(.glassControl)
                .font(.cueCaption)
                Button("View") {
                    app.openLibrary()
                }
                .buttonStyle(.glassControl)
                .font(.cueCaption)
                Button("Show in Finder") {
                    if let recording = app.justFinished { app.revealInFinder(recording) }
                }
                .buttonStyle(.glassControl)
                .font(.cueCaption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                     tint: Theme.success.opacity(0.5))
    }
}
