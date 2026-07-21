import SwiftUI
import AVKit

/// The recording library / share surface. A sidebar of past recordings and a
/// detail pane with playback + sharing — a preview of the eventual web share
/// page (s1 in the design references).
struct LibraryView: View {
    @EnvironmentObject private var app: AppState
    @State private var selection: Recording.ID?

    private var recordings: [Recording] { app.store.recordings }

    private var selected: Recording? {
        recordings.first { $0.id == selection } ?? recordings.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            if let recording = selected {
                RecordingDetailView(recording: recording)
                    .id(recording.id)
            } else {
                EmptyLibraryView()
            }
        }
        .background(VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow))
        .alert("Something went wrong",
               isPresented: Binding(get: { app.errorMessage != nil },
                                    set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(recordings) { recording in
                    LibraryRow(recording: recording)
                        .tag(recording.id)
                        .contextMenu { rowMenu(recording) }
                }
            } header: {
                HStack {
                    Text("Recordings").font(.cueSectionLabel)
                    Spacer()
                    if app.isLibrarySyncing {
                        ProgressView()
                            .controlSize(.small)
                            .help("Syncing with Cue server")
                    } else if app.uploadSettings.backend == .cueServer {
                        Button {
                            Task { await app.syncLibrary(showErrors: true) }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .help("Sync local and web Libraries")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if recordings.isEmpty {
                EmptyLibraryView()
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ recording: Recording) -> some View {
        if let url = recording.shareURL {
            Button("Copy Link") { app.copyLink(url.absoluteString) }
            switch recording.share {
            case .disabled:
                Button("Enable Link") { Task { await app.setShareDisabled(recording, disabled: false) } }
            default:
                Button("Disable Link") { Task { await app.setShareDisabled(recording, disabled: true) } }
            }
            Button("Remove from Cloud") { Task { await app.removeFromCloud(recording) } }
        }
        Button("Reveal in Finder") { app.revealInFinder(recording) }
        Divider()
        Button("Delete", role: .destructive) {
            if selection == recording.id { selection = nil }
            app.delete(recording)
        }
    }
}

// MARK: - Sidebar row

private struct LibraryRow: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording

    var body: some View {
        HStack(spacing: 10) {
            RecordingThumbnail(url: app.store.thumbnailURL(for: recording))
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(recording.formattedDuration)
                    Text("·")
                    ShareStatusBadge(recording: recording)
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

private struct RecordingDetailView: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                headerBlock
                playerBlock
                cameraStudioBlock
                shareBlock
                insightsBlock
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func isLinkDisabled(_ r: Recording) -> Bool {
        if case .disabled = r.share { return true }
        return false
    }

    /// Post-record camera reposition/resize — only for recordings that have a
    /// camera track and a saved composition plan (i.e. captured with post-edit
    /// support). `.id` resets the editor's state when the selection changes.
    @ViewBuilder
    private var cameraStudioBlock: some View {
        if let plan = recording.plan,
           recording.cameraFileName != nil || plan.activityFileName != nil {
            CameraStudioCard(recording: recording).id(recording.id)
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditableRecordingTitle(recording: recording)
            HStack(spacing: 8) {
                Label(recording.createdAt.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "calendar")
                Label(recording.formattedDuration, systemImage: "clock")
                Label(recording.captureMode.title, systemImage: recording.captureMode.systemImage)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private var playerBlock: some View {
        if let url = app.store.primaryMediaURL(for: recording) {
            // AppKit's AVPlayerView (not SwiftUI's VideoPlayer, whose generic
            // metadata instantiation crashes on this toolchain).
            PlayerView(url: url)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(.quaternary)
                .aspectRatio(16.0/10.0, contentMode: .fit)
                .overlay(Text("Media file missing").foregroundStyle(.secondary))
        }
    }

    private var shareBlock: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Share").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    ShareStatusBadge(recording: recording)
                }

                HStack(spacing: 8) {
                    Text(recording.shareURL?.absoluteString ?? "Not shared yet")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(recording.shareURL != nil ? Theme.accent : Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

                    if let url = recording.shareURL {
                        Button("Copy") { app.copyLink(url.absoluteString) }
                            .buttonStyle(.glassControl)
                    }
                }

                if let progress = app.uploadProgress[recording.id] {
                    ProgressView(value: progress) {
                        Text("Uploading… \(Int(progress * 100))%").font(.cueCaption)
                    }
                    .tint(Theme.accent)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            Task { await app.share(recording) }
                        } label: {
                            Label(recording.shareURL == nil ? "Upload to Cloud" : "Re-upload",
                                  systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.prominentGlass)

                        Button {
                            app.revealInFinder(recording)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.glassControl)
                    }
                    .font(.cueButton)

                    if recording.shareURL != nil {
                        HStack(spacing: 10) {
                            Button {
                                Task { await app.setShareDisabled(recording, disabled: !isLinkDisabled(recording)) }
                            } label: {
                                Label(isLinkDisabled(recording) ? "Enable Link" : "Disable Link",
                                      systemImage: isLinkDisabled(recording) ? "eye" : "eye.slash")
                            }
                            .buttonStyle(.glassControl)

                            Button(role: .destructive) {
                                Task { await app.removeFromCloud(recording) }
                            } label: {
                                Label("Remove from Cloud", systemImage: "icloud.slash")
                            }
                            .buttonStyle(.glassControl)
                        }
                        .font(.cueButton)
                    }
                }
            }
        }
    }

    private var insightsBlock: some View {
        AIInsightsCard(recording: recording)
    }
}

private struct EditableRecordingTitle: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording
    @State private var draft: String
    @State private var isEditing = false

    init(recording: Recording) {
        self.recording = recording
        _draft = State(initialValue: recording.title)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                TextField("Video title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .onSubmit { save() }

                Button("Cancel") {
                    draft = recording.title
                    isEditing = false
                }
                .buttonStyle(.glassControl)

                Button("Save") { save() }
                    .buttonStyle(.prominentGlass)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(recording.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                Button {
                    draft = recording.title
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.glassControl)
                .help("Rename recording")
            }
            Spacer(minLength: 0)
        }
        .onChange(of: recording.title) { _, title in
            if !isEditing { draft = title }
        }
    }

    private func save() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isEditing = false
        Task { await app.rename(recording, to: title) }
    }
}

// MARK: - AI insights

private enum InsightsTab: String, CaseIterable, Identifiable {
    case summary
    case transcript

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct AIInsightsCard: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording
    @State private var tab: InsightsTab = .summary

    private var phase: AppState.InsightGenerationPhase? {
        app.insightGeneration[recording.id]
    }

    private var isConfigured: Bool {
        app.uploadSettings.backend == .cueServer
            && !app.uploadSettings.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !app.uploadSettings.ownerToken.isEmpty
    }

    private var canRefresh: Bool {
        recording.uploadBackend == .cueServer && recording.shareURL != nil
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("AI insights", systemImage: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if let phase {
                        ProgressView()
                            .controlSize(.small)
                        Text(phase.title)
                            .font(.cueCaption)
                            .foregroundStyle(Theme.secondaryText)
                    } else if canRefresh {
                        Button {
                            Task { await app.refreshInsights(recording) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.glassControl)
                        .help("Refresh insights from the Cue server")
                    }
                }

                Picker("Insight", selection: $tab) {
                    ForEach(InsightsTab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)

                Group {
                    switch tab {
                    case .summary: summaryPane
                    case .transcript: transcriptPane
                    }
                }

                if !isConfigured {
                    Label("Choose Cue server and add its owner token in Settings to generate insights here.",
                          systemImage: "gearshape")
                        .font(.cueCaption)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("Local-only recordings are uploaded privately with their public link turned off. Results are saved in this Library.")
                        .font(.cueCaption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .onAppear { selectAvailableTab() }
        .onChange(of: recording.transcript) { _, newValue in
            if recording.summary == nil, newValue != nil { tab = .transcript }
        }
        .onChange(of: recording.summary) { _, newValue in
            if newValue != nil { tab = .summary }
        }
    }

    @ViewBuilder
    private var summaryPane: some View {
        if let summary = recording.summary, !summary.isEmpty {
            Text(summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await app.generateSummary(recording) }
            } label: {
                Label("Regenerate summary", systemImage: "sparkles")
            }
            .buttonStyle(.glassControl)
            .disabled(phase != nil || !isConfigured)
        } else {
            Text("Create a concise overview and key points from this recording’s audio.")
                .font(.cueCaption)
                .foregroundStyle(Theme.secondaryText)

            Button {
                Task { await app.generateSummary(recording) }
            } label: {
                Label("Generate summary", systemImage: "sparkles")
            }
            .buttonStyle(.prominentGlass)
            .disabled(phase != nil || !isConfigured)
        }
    }

    @ViewBuilder
    private var transcriptPane: some View {
        if let transcript = recording.transcript, !transcript.isEmpty {
            ScrollView {
                Text(transcript)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            HStack {
                Text("\(transcript.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.cueCaption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button {
                    Task { await app.generateTranscript(recording) }
                } label: {
                    Label("Re-transcribe", systemImage: "waveform")
                }
                .buttonStyle(.glassControl)
                .disabled(phase != nil || !isConfigured)
            }
        } else {
            Text("Turn the recording’s audio into searchable, selectable text.")
                .font(.cueCaption)
                .foregroundStyle(Theme.secondaryText)

            Button {
                Task { await app.generateTranscript(recording) }
            } label: {
                Label("Generate transcript", systemImage: "waveform")
            }
            .buttonStyle(.prominentGlass)
            .disabled(phase != nil || !isConfigured)
        }
    }

    private func selectAvailableTab() {
        if recording.summary != nil { tab = .summary }
        else if recording.transcript != nil { tab = .transcript }
    }
}

// MARK: - Camera studio (post-record reposition/resize)

/// Drag the camera bubble over a preview of the frame, set its size, then
/// re-render `final.mp4` from the recording's retained raw tracks.
private struct CameraStudioCard: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording
    @State private var placement: CameraPlacement
    @State private var cinematicEffects: Bool

    init(recording: Recording) {
        self.recording = recording
        _placement = State(initialValue: recording.plan?.cameraPlacement ?? .default)
        _cinematicEffects = State(initialValue: recording.plan?.cinematicEffectsEnabled ?? false)
    }

    private var busy: Bool { app.isRecomposing != nil }

    private var previewAspectRatio: CGFloat {
        guard let width = recording.width, let height = recording.height, height > 0 else { return 16.0 / 9.0 }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Studio", systemImage: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                Text("Re-render from the retained raw tracks. The edit replaces the local clip and drops the share back to local so you can re-upload.")
                    .font(.cueCaption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if recording.cameraFileName != nil {
                    Text("Camera position")
                        .font(.cueCaption)
                        .foregroundStyle(Theme.secondaryText)
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            RecordingThumbnail(url: app.store.thumbnailURL(for: recording))
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(.white.opacity(0.08)))

                            let d = max(20, geo.size.width * placement.size)
                            Circle()
                                .fill(Theme.accent.opacity(0.20))
                                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                                .frame(width: d, height: d)
                                .position(x: placement.centerX * geo.size.width,
                                          y: placement.centerY * geo.size.height)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let radius = placement.size / 2
                                            placement.centerX = min(max(value.location.x / geo.size.width, radius), 1 - radius)
                                            placement.centerY = min(max(value.location.y / geo.size.height, radius), 1 - radius)
                                        }
                                )
                        }
                    }
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 10) {
                        Text("Size").font(.cueCaption).foregroundStyle(Theme.secondaryText)
                        Slider(value: $placement.size, in: 0.12...0.45)
                    }
                }

                if recording.plan?.activityFileName != nil {
                    Toggle(isOn: $cinematicEffects) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Click cinematography").font(.system(size: 12.5, weight: .medium))
                            Text("Adds click ripples and gentle auto-zoom; new recordings also use a smoothed cursor.")
                                .font(.cueCaption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Button {
                    Task {
                        await app.recompose(
                            recording,
                            placement: recording.cameraFileName == nil ? nil : placement,
                            cinematicEffects: cinematicEffects
                        )
                    }
                } label: {
                    Label(busy ? "Re-rendering…" : "Apply Studio edits",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(.prominentGlass)
                .disabled(busy)
            }
        }
    }
}

// MARK: - Shared bits

struct RecordingThumbnail: View {
    let url: URL?

    var body: some View {
        ZStack {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}

struct ShareStatusBadge: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording

    var body: some View {
        let (text, color) = status
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    private var status: (String, Color) {
        if app.uploadProgress[recording.id] != nil { return ("Uploading", Theme.accent) }
        switch recording.share {
        case .local: return ("On this Mac", Theme.secondaryText)
        case .uploading: return ("Uploading", Theme.accent)
        case .shared: return ("Shared", Theme.success)
        case .disabled: return ("Link off", .orange)
        case .failed: return ("Failed", Theme.recording)
        }
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 12) {
            BrandMarkLarge()
            Text("No recordings yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Click the Cue icon in the menu bar to record your first video.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrandMarkLarge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Theme.accent, Theme.teal],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(.white).frame(width: 18, height: 18)
        }
        .frame(width: 56, height: 56)
        .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 3)
    }
}

// MARK: - Player

/// Wraps AppKit's `AVPlayerView`. Used instead of SwiftUI's `VideoPlayer`,
/// which crashes during Swift generic-metadata instantiation (`_AVKit_SwiftUI`
/// `getSuperclassMetadata`) on the current toolchain.
private struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let currentURL = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else { return }
        view.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
