import Foundation
import AVFoundation
import SwiftUI

/// Drives the Creative Editor: a live preview built from the recording's raw
/// tracks, edits applied to a working copy of its `CompositionPlan`, and a
/// final render that replaces the video.
///
/// The preview runs the real compositor through `AVPlayerItem.videoComposition`,
/// so what plays is what will be exported — just at half size. Dragging only
/// swaps the video composition; the tracks are built once.
@MainActor
final class CreativeEditorModel: ObservableObject {

    /// The recording being edited. Re-read from the store after each render so
    /// a long-lived editor window never writes back a stale copy over edits
    /// made in the Library.
    private(set) var recording: Recording
    private unowned let app: AppState

    @Published var plan: CompositionPlan
    @Published private(set) var player = AVPlayer()
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    /// Aspect ratio of the composed frame, so the preview box matches the output.
    @Published private(set) var previewAspect: CGFloat = 9.0 / 16.0
    /// Camera frame aspect, used to draw the drag handle at the right shape.
    @Published private(set) var cameraAspect: CGFloat = 3.0 / 4.0
    /// Set once the user moves the person, so switching layouts stops resetting
    /// a placement they chose deliberately.
    @Published private(set) var hasCustomPlacement = false

    private var built: VideoComposer.BuiltComposition?
    private var playerItem: AVPlayerItem?
    private var captions: [CaptionCue] = []
    private var mouseActivity: MouseActivity?
    private var refreshTask: Task<Void, Never>?
    private let workdir: URL

    /// Preview renders at half the export size — a quarter of the pixels, which
    /// is what keeps scrubbing responsive through per-frame segmentation.
    private static let previewScale: CGFloat = 0.5

    init(recording: Recording, app: AppState) {
        self.recording = recording
        self.app = app
        var plan = recording.plan ?? CompositionPlan(
            bubbleShape: .circle, mirrored: false, cameraBackground: .transparent,
            corner: .bottomLeft, padding: 0, background: .none, aspectRatio: nil,
            fps: 30, cameraStartOffset: nil, leadTrim: nil,
            cameraHiddenRanges: [], screenPauseSpans: [], cameraPauseSpans: [])
        // Opening the creative editor on a landscape clip starts it off in the
        // vertical format — that's what the user came here for.
        if plan.creativeLayout == nil {
            plan.creativeLayout = recording.cameraFileName == nil && recording.screenFileName == nil
                ? .personOnly
                : (recording.captureMode == .cameraOnly ? .personOnly : .screenFill)
            plan.cameraStyle = .cutout
        }
        self.hasCustomPlacement = recording.plan?.cutoutPlacement != nil
        self.plan = plan
        self.workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-editor-\(recording.id.uuidString)", isDirectory: true)
    }

    var layout: CreativeLayout { plan.creativeLayout ?? .screenFill }
    var placement: CameraPlacement {
        plan.cutoutPlacement ?? layout.defaultCutoutPlacement
    }
    var isRendering: Bool { app.isRecomposing == recording.id }
    var hasCamera: Bool {
        recording.cameraFileName != nil || recording.captureMode == .cameraOnly
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        loadError = nil
        let folder = app.store.folderURL(for: recording.id)
        let screenURL = recording.screenFileName.map { folder.appendingPathComponent($0) }
        let cameraURL = recording.cameraFileName.map { folder.appendingPathComponent($0) }

        captions = CaptionGenerator.loadTrack(for: recording, store: app.store)?.cues ?? []
        if plan.cinematicEffectsEnabled == true, let name = plan.activityFileName,
           let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
            mouseActivity = try? JSONDecoder().decode(MouseActivity.self, from: data)
        }

        do {
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            let built = try await VideoComposer.buildComposition(
                plan: plan, screenURL: screenURL, cameraURL: cameraURL,
                previewScale: Self.previewScale, workdir: workdir)
            self.built = built
            if built.renderSize.height > 0 {
                previewAspect = built.renderSize.width / built.renderSize.height
            }
            if let cameraURL, let track = try? await AVURLAsset(url: cameraURL)
                .loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.height > 0 {
                cameraAspect = size.width / size.height
            } else if built.baseIsCamera, built.sourceAspect > 0 {
                cameraAspect = built.sourceAspect
            }

            let item = AVPlayerItem(asset: built.composition)
            item.seekingWaitsForVideoCompositionRendering = true
            item.videoComposition = VideoComposer.makeVideoComposition(
                for: built, plan: plan, mouseActivity: mouseActivity, captions: captions)
            playerItem = item
            player.replaceCurrentItem(with: item)
            isLoading = false
        } catch {
            NSLog("Cue editor preview failed to build: \(error)")
            loadError = "Cue couldn't build a preview from this recording's video files."
            isLoading = false
        }
    }

    func teardown() {
        refreshTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerItem = nil
        built = nil
        try? FileManager.default.removeItem(at: workdir)
    }

    // MARK: Edits

    func setLayout(_ layout: CreativeLayout) {
        plan.creativeLayout = layout
        plan.cameraStyle = .cutout
        if !hasCustomPlacement { plan.cutoutPlacement = layout.defaultCutoutPlacement }
        refreshPreview()
    }

    func movePerson(toCenterX x: Double, centerY y: Double) {
        var next = placement
        next.centerX = min(max(x, -0.2), 1.2)
        // Past the bottom edge is allowed on purpose: it's how you get the
        // waist-up framing short-form video uses.
        next.centerY = min(max(y, -0.2), 1.35)
        plan.cutoutPlacement = next
        hasCustomPlacement = true
        refreshPreview(debounced: true)
    }

    func resizePerson(to size: Double) {
        var next = placement
        next.size = min(max(size, 0.2), 1.2)
        plan.cutoutPlacement = next
        hasCustomPlacement = true
        refreshPreview(debounced: true)
    }

    func setMirrored(_ mirrored: Bool) {
        plan.mirrored = mirrored
        refreshPreview()
    }

    func setCaptionsEnabled(_ enabled: Bool) {
        plan.captionsEnabled = enabled
        // The render reads the cues back from the sidecar, so the plan has to
        // point at it — otherwise the captions in this preview wouldn't make it
        // into the finished video.
        if enabled, hasCaptions { plan.captionsFileName = CaptionTrack.fileName }
        refreshPreview()
    }

    func setCaptionStyle(_ style: CaptionStyle) {
        plan.captionStyle = style
        refreshPreview()
    }

    func resetPlacement() {
        plan.cutoutPlacement = layout.defaultCutoutPlacement
        hasCustomPlacement = false
        refreshPreview()
    }

    var hasCaptions: Bool { !captions.isEmpty }

    /// Generates a caption track for a recording that doesn't have one yet, then
    /// shows it in the preview.
    func generateCaptions() async {
        guard let updated = await app.generateCaptions(for: recording) else { return }
        recording = updated
        captions = CaptionGenerator.loadTrack(for: updated, store: app.store)?.cues ?? []
        plan.captionsEnabled = true
        plan.captionStyle = updated.plan?.captionStyle ?? plan.captionStyle
        plan.captionsFileName = CaptionTrack.fileName
        refreshPreview()
    }

    // MARK: Preview refresh

    /// Rebuilds only the video composition. Debounced during a drag so a
    /// gesture doesn't queue up dozens of rebuilds.
    private func refreshPreview(debounced: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: .milliseconds(90))
                if Task.isCancelled { return }
            }
            self?.applyPreview()
        }
    }

    private func applyPreview() {
        guard let built, let playerItem else { return }
        playerItem.videoComposition = VideoComposer.makeVideoComposition(
            for: built, plan: plan, mouseActivity: mouseActivity, captions: captions)
        // A paused player keeps showing the old frame until something makes it
        // draw again.
        if player.timeControlStatus != .playing {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: Render

    /// Re-renders the video at full size and replaces the recording's final cut.
    func renderAndReplace() async {
        player.pause()
        if let updated = await app.recompose(recording, plan: plan) { recording = updated }
    }
}
