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
                Text("Recordings").font(.cueSectionLabel)
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
        if recording.cameraFileName != nil, recording.plan != nil {
            CameraStudioCard(recording: recording).id(recording.id)
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.title)
                .font(.system(size: 22, weight: .bold))
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
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            insightCard(title: "Summary", systemImage: "text.alignleft",
                        body: "AI summary, smart chapters, and a searchable transcript arrive in Phase 2.")
            insightCard(title: "Reactions", systemImage: "face.smiling",
                        body: "Timestamped emoji reactions and threaded comments are coming on the web player.")
        }
    }

    private func insightCard(title: String, systemImage: String, body: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(body)
                    .font(.cueCaption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Coming soon")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Camera studio (post-record reposition/resize)

/// Drag the camera bubble over a preview of the frame, set its size, then
/// re-render `final.mp4` from the recording's retained raw tracks.
private struct CameraStudioCard: View {
    @EnvironmentObject private var app: AppState
    let recording: Recording
    @State private var placement: CameraPlacement

    init(recording: Recording) {
        self.recording = recording
        _placement = State(initialValue: recording.plan?.cameraPlacement ?? .default)
    }

    private var busy: Bool { app.isRecomposing == recording.id }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Camera position", systemImage: "person.crop.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                Text("Drag the bubble to reposition it and set its size, then re-render. The edit replaces the local clip and drops the share back to local so you can re-upload.")
                    .font(.cueCaption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

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
                                        placement.centerX = min(max(value.location.x / geo.size.width, 0), 1)
                                        placement.centerY = min(max(value.location.y / geo.size.height, 0), 1)
                                    }
                            )
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Text("Size").font(.cueCaption).foregroundStyle(Theme.secondaryText)
                    Slider(value: $placement.size, in: 0.12...0.45)
                }

                Button {
                    Task { await app.recompose(recording, placement: placement) }
                } label: {
                    Label(busy ? "Re-rendering…" : "Re-render with new position",
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
