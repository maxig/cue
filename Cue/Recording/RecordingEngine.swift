import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit
import QuartzCore

/// Orchestrates a capture session: builds the ScreenCaptureKit filter, drives
/// the screen + camera recorders into separate tracks, then on stop composes a
/// single shareable `final.mp4` (camera PiP baked in + system/mic audio mixed).
@MainActor
final class RecordingEngine: ObservableObject {

    private let store: RecordingStore
    private let camera: CameraEngine
    private let screenRecorder = ScreenRecorder()

    private var currentID: UUID?
    private var startDate: Date?
    /// Host-clock time the countdown elapsed and the *content* began. Everything
    /// captured before this (countdown lead-in + stream warm-up) is trimmed off.
    private var contentStartAnchor: CFTimeInterval?
    private var folder: URL?
    private var mode: CaptureMode = .screen
    private var usedCamera = false
    private var usedScreen = false
    private var bubbleShape: CameraBubbleShape = .circle
    private var cameraMirrored = false
    private var cameraBackground: CameraBackground = .none
    private var cameraCorner: CameraCorner = .bottomLeft
    private var screenPadding: Double = 0
    private var canvasBackground: CanvasBackground = .none
    private var aspectMode: AspectRatioMode = .sixteenNine
    /// The capture frame rate chosen at `start` (30 or 60). Remembered so the
    /// final composition is rendered at the same rate instead of a fixed 30.
    private var captureFPS: Int = 30

    // Pause + camera-toggle bookkeeping (composition-time seconds).
    private var pausedWallTotal: Double = 0
    private var pauseStartWall: CFTimeInterval?
    /// Host-clock spans the user spent paused. The camera keeps rolling through
    /// pauses (so the bubble never freezes), and these spans are cut out of the
    /// camera track at compose time to keep it locked to the pause-compressed
    /// screen track.
    private var pauseSpansHost: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var cameraDisabledRanges: [ClosedRange<Double>] = []
    private var cameraDisableStart: Double?
    private var cameraIsOn = true

    var onStreamError: ((Error) -> Void)? {
        didSet { screenRecorder.onStreamError = onStreamError }
    }

    init(store: RecordingStore, camera: CameraEngine) {
        self.store = store
        self.camera = camera
    }

    // MARK: Start

    func start(config: CaptureConfiguration,
               bubbleShape: CameraBubbleShape,
               mirrored: Bool,
               cameraBackground: CameraBackground,
               corner: CameraCorner,
               padding: Double,
               background: CanvasBackground,
               aspectMode: AspectRatioMode,
               fps: Int = 30) async throws {
        guard currentID == nil else { throw RecordingError.alreadyRecording }

        let id = UUID()
        let folder = store.folderURL(for: id)
        self.currentID = id
        self.folder = folder
        self.mode = config.mode
        self.bubbleShape = bubbleShape
        self.cameraMirrored = mirrored
        self.cameraBackground = cameraBackground
        self.cameraCorner = corner
        self.screenPadding = padding
        self.canvasBackground = background
        self.aspectMode = aspectMode
        self.captureFPS = fps
        self.usedCamera = false
        self.usedScreen = false
        self.contentStartAnchor = nil
        self.pausedWallTotal = 0
        self.pauseStartWall = nil
        self.pauseSpansHost = []
        self.cameraDisabledRanges = []
        self.cameraDisableStart = nil
        self.cameraIsOn = true

        let micID = (config.microphoneEnabled && config.microphone?.isNone == false)
            ? config.microphone?.id : nil

        // Screen track (all modes except camera-only)
        if config.mode != .cameraOnly {
            guard let (width, height, filter) = await makeFilterAndSize(config: config) else {
                reset()
                throw RecordingError.noCaptureTarget
            }
            let options = ScreenRecorder.Options(
                filter: filter,
                width: width,
                height: height,
                fps: fps,
                captureSystemAudio: config.captureSystemAudio,
                captureMicrophone: micID != nil,
                microphoneDeviceID: micID,
                outputFolder: folder
            )
            try await screenRecorder.start(options: options)
            usedScreen = true
        }

        // Camera track (session/preview already started by AppState)
        let wantsCamera = config.mode == .cameraOnly
            || (config.cameraEnabled && config.camera?.isNone == false && config.camera != nil)
        if wantsCamera, config.camera?.isNone == false {
            camera.beginRecording(to: folder.appendingPathComponent("camera.mov"))
            usedCamera = true
        }

        startDate = Date()
    }

    /// Marks the moment the countdown elapsed and the content begins. The lead-in
    /// captured before this is trimmed away by the composer.
    func markContentStart() {
        contentStartAnchor = CACurrentMediaTime()
        startDate = Date()
    }

    // MARK: In-recording controls

    func pause() {
        if pauseStartWall == nil { pauseStartWall = CACurrentMediaTime() }
        // Neither the screen nor the camera recorder is actually paused: pausing
        // one encoder while the other keeps running left the paused track unable
        // to resume (the screen video — or the camera — would cut off at the
        // pause). Both keep rolling continuously and the paused span is excised
        // from every track at compose time — see `pauseSpansHost`.
    }

    func resume() {
        if let ps = pauseStartWall {
            let now = CACurrentMediaTime()
            pausedWallTotal += now - ps
            pauseSpansHost.append((ps, now))
            pauseStartWall = nil
        }
    }

    func setMicMuted(_ muted: Bool) {
        screenRecorder.setMicMuted(muted)
        // Camera-only recordings capture the mic via the camera session, so mute
        // there too. No-op in screen+camera mode (camera session has no audio).
        if usedCamera { camera.setMicMuted(muted) }
    }

    /// Toggles the camera in the *output* (the live bubble is handled by AppState).
    /// Off-periods are recorded as composition-time ranges and the PiP is hidden
    /// across them by the compositor; the camera file keeps rolling continuously.
    func setCameraOn(_ on: Bool) {
        guard usedCamera, on != cameraIsOn else { return }
        cameraIsOn = on
        if on {
            if let start = cameraDisableStart {
                cameraDisabledRanges.append(start...max(start, compositionNow()))
                cameraDisableStart = nil
            }
        } else {
            cameraDisableStart = compositionNow()
        }
    }

    /// Seconds into the (paused-time-excluded) content timeline right now.
    private func compositionNow() -> Double {
        guard let anchor = contentStartAnchor else { return 0 }
        var t = CACurrentMediaTime() - anchor - pausedWallTotal
        if let ps = pauseStartWall { t -= (CACurrentMediaTime() - ps) }
        return max(0, t)
    }

    /// Aborts an in-progress capture (e.g. the user cancels during the countdown)
    /// and deletes its files without composing anything.
    func cancel() async {
        guard currentID != nil else { return }
        if usedScreen { _ = await screenRecorder.stop() }
        if usedCamera { await camera.stopRecording() }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        reset()
    }

    // MARK: Stop

    /// Stops capture and composes the final clip. `onCaptureFinished` fires the
    /// moment the raw tracks are finalized — before the (potentially slow)
    /// composition — so the caller can release the camera device and tear down
    /// the live UI immediately rather than holding them through processing.
    func stop(onCaptureFinished: () -> Void = {}) async -> Recording? {
        guard let id = currentID, let start = startDate, let folder else { return nil }

        var screenName: String?
        if usedScreen {
            let result = await screenRecorder.stop()
            screenName = result.screenFileName
        }
        if usedCamera { await camera.stopRecording() }

        // Raw tracks are on disk now; nothing below needs the live camera/screen.
        onCaptureFinished()

        let duration = Date().timeIntervalSince(start)
        let cameraName = usedCamera ? "camera.mov" : nil

        // How long after the screen/audio did the camera actually start? Used to
        // place the camera PiP at the right spot in the timeline.
        let cameraOffset: Double? = {
            guard usedCamera,
                  let screenAnchor = screenRecorder.firstFrameAnchor,
                  let cameraAnchor = camera.recordingStartAnchor else { return nil }
            return max(0, cameraAnchor - screenAnchor)
        }()

        // How much of the head (countdown + warm-up) to trim so the clip starts
        // exactly at content-start, with every stream already rolling.
        let baseAnchor = usedScreen ? screenRecorder.firstFrameAnchor : camera.recordingStartAnchor
        let leadTrim: Double? = {
            guard let contentStart = contentStartAnchor, let baseAnchor else { return nil }
            return max(0, contentStart - baseAnchor)
        }()

        // If we're stopped while still paused, close the open span first.
        if let ps = pauseStartWall {
            pauseSpansHost.append((ps, CACurrentMediaTime()))
            pauseStartWall = nil
        }

        // Both tracks record continuously through pauses; the composer cuts the
        // paused spans out of each. Spans are expressed per-file (seconds from
        // that track's first frame) since screen and camera start at slightly
        // different anchors — cutting the same wall-clock spans keeps them locked.
        func spans(relativeTo anchor: CFTimeInterval?) -> [ClosedRange<Double>] {
            guard let anchor else { return [] }
            return pauseSpansHost
                .map { max(0, $0.start - anchor)...max(0, $0.end - anchor) }
                .filter { $0.upperBound > $0.lowerBound }
        }
        let screenPauseSpans = usedScreen ? spans(relativeTo: screenRecorder.firstFrameAnchor) : []
        let cameraPauseSpans = usedCamera ? spans(relativeTo: camera.recordingStartAnchor) : []

        // If the recording ended with the camera toggled off, close that range.
        if let start = cameraDisableStart {
            cameraDisabledRanges.append(start...max(start, compositionNow()))
            cameraDisableStart = nil
        }

        // Compose the shareable final.mp4 (camera PiP + synced audio + canvas).
        var finalName: String?
        var audioName: String?
        var size = CGSize.zero
        do {
            let output = try await VideoComposer.compose(
                screenURL: screenName.map { folder.appendingPathComponent($0) },
                cameraURL: cameraName.map { folder.appendingPathComponent($0) },
                bubbleShape: bubbleShape,
                mirrored: cameraMirrored,
                cameraBackground: cameraBackground,
                corner: cameraCorner,
                padding: screenPadding,
                background: canvasBackground,
                aspectRatio: aspectMode.ratio,
                fps: captureFPS,
                cameraStartOffset: cameraOffset,
                leadTrim: leadTrim,
                cameraHiddenRanges: cameraDisabledRanges,
                screenPauseSpans: screenPauseSpans,
                cameraPauseSpans: cameraPauseSpans,
                outputURL: folder.appendingPathComponent("final.mp4")
            )
            finalName = "final.mp4"
            audioName = output.audioURL?.lastPathComponent
            size = output.size
        } catch {
            // Composition failed — keep the raw tracks; primary falls back to screen/camera.
            NSLog("Cue compose failed: \(error.localizedDescription)")
        }

        let thumbSource = finalName.map { folder.appendingPathComponent($0) }
            ?? screenName.map { folder.appendingPathComponent($0) }
            ?? cameraName.map { folder.appendingPathComponent($0) }
        let thumbName = await generateThumbnail(id: id, sourceURL: thumbSource)

        let recording = Recording(
            id: id,
            title: Self.defaultTitle(),
            duration: duration,
            screenFileName: screenName,
            cameraFileName: cameraName,
            finalFileName: finalName,
            audioFileName: audioName,
            thumbnailFileName: thumbName,
            width: size == .zero ? nil : Int(size.width),
            height: size == .zero ? nil : Int(size.height),
            captureMode: mode,
            share: .local
        )
        store.upsert(recording)
        reset()
        return recording
    }

    private func reset() {
        currentID = nil
        startDate = nil
        folder = nil
        usedCamera = false
        usedScreen = false
    }

    // MARK: Helpers

    private func makeFilterAndSize(config: CaptureConfiguration) async -> (Int, Int, SCContentFilter)? {
        switch config.mode {
        case .window:
            // Window capture already isolates the single window — the floating
            // camera bubble / region frame are never part of it.
            guard let window = config.window?.scWindow else { return nil }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let size = evenClampedSize(width: window.frame.width * scale,
                                       height: window.frame.height * scale)
            return (size.0, size.1, SCContentFilter(desktopIndependentWindow: window))
        default:
            guard let display = config.display?.scDisplay else { return nil }
            let scale = backingScale(for: display.displayID)
            let size = evenClampedSize(width: CGFloat(display.width) * scale,
                                       height: CGFloat(display.height) * scale)
            // Exclude all of Cue's own windows (camera bubble, capture-region
            // frame, countdown overlay, popover) so none of them are baked into
            // the recorded display — otherwise the live bubble would appear in
            // the video on top of the composited camera PiP.
            let excluded = await ownApplications()
            let filter = SCContentFilter(display: display,
                                         excludingApplications: excluded,
                                         exceptingWindows: [])
            return (size.0, size.1, filter)
        }
    }

    /// Cue's own running application(s), used to exclude its windows from capture.
    private func ownApplications() async -> [SCRunningApplication] {
        guard let content = try? await SCShareableContent.current else { return [] }
        let bundleID = Bundle.main.bundleIdentifier
        return content.applications.filter { $0.bundleIdentifier == bundleID }
    }

    private func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(number.uint32Value) == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func evenClampedSize(width: CGFloat, height: CGFloat) -> (Int, Int) {
        var w = max(2, width)
        var h = max(2, height)
        let maxDimension: CGFloat = 3840
        let longest = max(w, h)
        if longest > maxDimension {
            let ratio = maxDimension / longest
            w *= ratio
            h *= ratio
        }
        var iw = Int(w.rounded())
        var ih = Int(h.rounded())
        if iw % 2 != 0 { iw -= 1 }
        if ih % 2 != 0 { ih -= 1 }
        return (iw, ih)
    }

    private func generateThumbnail(id: UUID, sourceURL: URL?) async -> String? {
        guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        do {
            let time = CMTime(seconds: 0.4, preferredTimescale: 600)
            let cgImage = try await generator.image(at: time).image
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
                return nil
            }
            let url = store.folderURL(for: id).appendingPathComponent("thumb.jpg")
            try data.write(to: url, options: .atomic)
            return "thumb.jpg"
        } catch {
            return nil
        }
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Cue · \(formatter.string(from: Date()))"
    }
}
