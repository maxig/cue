import Foundation
import SwiftUI
import AppKit
import Combine
import AVFoundation

/// The root view-model. Owns the subsystems and the recording state machine,
/// and is injected into every view as an `@EnvironmentObject`.
@MainActor
final class AppState: ObservableObject {

    // Subsystems
    let permissions = PermissionsManager()
    let devices = DeviceManager()
    let store = RecordingStore()
    let uploadSettings = UploadSettings()
    let preferences = Preferences()
    let overlay = OverlayController()
    let cameraEngine = CameraEngine()
    let cameraBubble = CameraBubbleController()
    let captureIndicator = CaptureRegionIndicator()
    private(set) lazy var engine = RecordingEngine(store: store, camera: cameraEngine)

    /// Live-preview (popover-open) state: whether the camera/region preview is
    /// active, and a signature of the camera inputs currently wired, so we can
    /// keep the session warm across popover reopens instead of restarting it.
    private var livePreviewActive = false
    private var previewSignature: String?
    private var didRestoreMode = false

    // Capture configuration (bound to the popover controls)
    @Published var config = CaptureConfiguration()

    // Recording state machine
    enum RecordingState: Equatable {
        case idle
        case countdown(Int)
        case recording
        case processing
    }
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    // In-recording controls (mic mute / camera off / pause)
    @Published private(set) var isPaused = false
    @Published private(set) var micActive = true
    @Published private(set) var cameraActive = true

    /// Whether the popover is currently showing the Settings screen.
    @Published var showSettings = false

    // Sharing / library surface
    @Published var uploadProgress: [UUID: Double] = [:]
    /// Id of the recording currently being re-rendered (post-record studio edit).
    @Published var isRecomposing: UUID?
    @Published var lastShareURL: URL?
    @Published var justFinished: Recording?
    @Published var errorMessage: String?

    private var elapsedTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        engine.onStreamError = { [weak self] error in
            Task { @MainActor in self?.handleStreamError(error) }
        }
        // Forward changes from nested observable subsystems so views observing
        // AppState (via `app.store`, `app.devices`, …) refresh correctly.
        for publisher in [permissions.objectWillChange,
                          devices.objectWillChange,
                          store.objectWillChange,
                          uploadSettings.objectWillChange,
                          preferences.objectWillChange] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: Derived state

    var isRecording: Bool { if case .recording = state { return true }; return false }
    var isCountingDown: Bool { if case .countdown = state { return true }; return false }
    var isProcessing: Bool { state == .processing }
    var isBusy: Bool { state != .idle }

    var menuBarTitle: String? {
        switch state {
        case .recording: return elapsed.clockString
        case .countdown(let n): return "\(n)"
        case .processing: return "•••"
        case .idle: return nil
        }
    }

    var menuBarSymbol: String {
        switch state {
        case .recording: return "stop.circle.fill"
        case .countdown: return "timer"
        case .processing: return "arrow.up.circle"
        case .idle: return "record.circle"
        }
    }

    // MARK: Device refresh

    func refreshEverything() async {
        permissions.refresh()
        devices.refreshAVDevices()
        let screenWorking = await devices.refreshScreenContent()
        permissions.reflectScreenRecording(working: screenWorking)
        ensureSelections()
    }

    func ensureSelections() {
        // Restore the last-used capture mode on first population.
        if !didRestoreMode {
            config.mode = preferences.lastMode
            didRestoreMode = true
        }
        if config.display == nil { config.display = devices.displays.first }
        if config.window == nil || !devices.windows.contains(where: { $0.id == config.window?.id }) {
            config.window = devices.windows.first
        }
        if config.camera == nil {
            config.camera = Self.resolve(devices.cameras, savedID: preferences.lastCameraID)
                ?? devices.cameras.first ?? .none("No Camera")
        }
        if config.microphone == nil {
            config.microphone = Self.resolve(devices.microphones, savedID: preferences.lastMicrophoneID)
                ?? devices.microphones.first ?? .none("No Audio")
        }
    }

    /// Returns the saved device if it's still present, else nil.
    private static func resolve(_ options: [DeviceOption], savedID: String?) -> DeviceOption? {
        guard let savedID else { return nil }
        return options.first { $0.id == savedID }
    }

    /// Persists the current camera/mic/mode picks so they survive a relaunch.
    func persistDeviceSelections() {
        if let id = config.camera?.id, config.camera?.isNone == false { preferences.lastCameraID = id }
        if let id = config.microphone?.id, config.microphone?.isNone == false { preferences.lastMicrophoneID = id }
        preferences.lastMode = config.mode
    }

    // MARK: Recording lifecycle

    func toggleRecording() {
        if isRecording || isCountingDown {
            Task { await stop() }
        } else {
            start()
        }
    }

    func start() {
        guard !isBusy else { return }

        if config.mode != .cameraOnly && !permissions.canRecordScreen {
            permissions.requestScreenRecording()
            if !permissions.canRecordScreen {
                errorMessage = "Screen Recording permission is needed. Enable Cue under System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch."
                return
            }
        }

        startCameraPreviewIfNeeded()
        overlay.show(appState: self)

        let seconds = config.countdownSeconds
        state = seconds > 0 ? .countdown(seconds) : .recording

        // Begin capturing IMMEDIATELY — both the screen and the camera roll
        // throughout the countdown so they're fully warmed up and frame-locked
        // before the content begins. The countdown lead-in is trimmed off in the
        // composer (`markContentStart`), so the final clip starts cleanly with
        // both streams already present and in sync — no camera "gap" at the head.
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.start(config: self.config,
                                            bubbleShape: self.preferences.cameraBubbleShape,
                                            mirrored: self.preferences.cameraMirrored,
                                            cameraBackground: self.preferences.cameraBackground,
                                            corner: self.preferences.cameraCorner,
                                            padding: self.preferences.screenPadding,
                                            background: self.preferences.canvasBackground,
                                            aspectMode: self.preferences.aspectMode,
                                            fps: self.preferences.captureFPS)
                if seconds <= 0 { self.enterRecording() }
            } catch {
                self.errorMessage = error.localizedDescription
                self.state = .idle
                self.overlay.hide()
                self.teardownCamera()
            }
        }

        if seconds > 0 {
            countdownTask = Task { [weak self] in
                guard let self else { return }
                for n in stride(from: seconds, through: 1, by: -1) {
                    self.state = .countdown(n)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self.enterRecording()
            }
        }
    }

    /// The countdown has elapsed — mark "content start" (the trim point) and flip
    /// to the recording state. Capture is already running by now.
    private func enterRecording() {
        guard isCountingDown || state == .recording else { return }
        engine.markContentStart()
        state = .recording
        isPaused = false
        micActive = config.microphoneEnabled && config.microphone?.isNone == false
        cameraActive = config.cameraEnabled && config.camera?.isNone == false
        captureIndicator.hide()   // the region hint must never appear in the video
        elapsed = 0
        startElapsedTimer()
    }

    // MARK: In-recording controls

    var hasMicSource: Bool { config.microphoneEnabled && config.microphone?.isNone == false }
    var hasCameraSource: Bool { config.cameraEnabled && config.camera?.isNone == false }

    func togglePause() {
        guard state == .recording else { return }
        isPaused.toggle()
        if isPaused {
            engine.pause()
            stopElapsedTimer()
        } else {
            engine.resume()
            startElapsedTimer()
        }
    }

    func toggleMic() {
        guard state == .recording, hasMicSource, !isPaused else { return }
        micActive.toggle()
        engine.setMicMuted(!micActive)
    }

    func toggleCamera() {
        guard state == .recording, hasCameraSource, !isPaused else { return }
        cameraActive.toggle()
        engine.setCameraOn(cameraActive)
        cameraBubble.setHidden(!cameraActive)
    }

    func stop() async {
        countdownTask?.cancel()
        countdownTask = nil
        stopElapsedTimer()

        switch state {
        case .recording:
            if isPaused { engine.resume(); isPaused = false }
            state = .processing
            // Tear down the live surfaces immediately — the control bar, camera
            // bubble and region hint all go away the instant Stop is hit, since
            // compositing happens off-screen from the files on disk.
            overlay.hide()
            cameraBubble.hide()
            captureIndicator.hide()
            // `engine.stop` releases the camera device (green light off) as soon
            // as the raw tracks are written, not after the whole composition.
            let recording = await engine.stop { [weak self] in
                self?.cameraEngine.stopSession()
                self?.livePreviewActive = false
                self?.previewSignature = nil
            }
            state = .idle
            if let recording {
                justFinished = recording
                await share(recording)
            }
        case .countdown:
            // Capture is already rolling during the countdown — discard it.
            state = .idle
            await engine.cancel()
            overlay.hide()
            teardownCamera()
        default:
            state = .idle
            overlay.hide()
            teardownCamera()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        state = .idle
        Task { await engine.cancel() }
        overlay.hide()
        teardownCamera()
    }

    // MARK: Live preview (camera + capture region shown while the popover is open)

    /// Called when the recorder popover appears. Brings up the live camera
    /// bubble and the red capture-region indicator, Loom-style, so the user sees
    /// exactly what will be recorded — and keeps the camera warm for tight sync.
    func popoverDidAppear() {
        guard state == .idle else { return }
        livePreviewActive = true
        updateCaptureIndicator()
        startCameraPreviewIfNeeded()
    }

    /// Called when the popover closes. Tears the preview down only if we're idle;
    /// once a countdown/recording is under way the camera must keep running.
    func popoverDidDisappear() {
        guard state == .idle else { return }
        teardownCamera()
    }

    /// Called when the source/camera selection changes while the popover is open,
    /// so the indicator and camera preview track the current configuration.
    func liveSelectionChanged() {
        guard state == .idle, livePreviewActive else { return }
        updateCaptureIndicator()
        let wantsCamera = config.mode == .cameraOnly
            || (preferences.showCameraBubble && config.cameraEnabled && config.camera?.isNone == false)
        if wantsCamera {
            startCameraPreviewIfNeeded()
        } else if cameraEngine.isRunning {
            cameraBubble.hide()
            cameraEngine.stopSession()
            previewSignature = nil
        }
    }

    private func updateCaptureIndicator() {
        guard state == .idle, livePreviewActive, config.mode != .cameraOnly,
              let rect = captureRegionRect() else {
            captureIndicator.hide()
            return
        }
        captureIndicator.show(rect: rect, label: captureRegionLabel())
    }

    /// Starts (or keeps warm) the camera preview. Idempotent: if the session is
    /// already running with the same inputs it does nothing but re-show the
    /// bubble, so flipping the popover open/closed doesn't churn the camera.
    private func startCameraPreviewIfNeeded() {
        let cameraOnly = config.mode == .cameraOnly
        let wantsCamera = cameraOnly || (config.cameraEnabled && config.camera?.isNone == false)
        guard wantsCamera, config.camera?.isNone == false, let cameraID = config.camera?.id else { return }
        // No bubble means no preview surface (and recording will still capture the
        // camera at record-time); don't warm the camera for nothing.
        guard cameraOnly || preferences.showCameraBubble else { return }

        let includeAudio = cameraOnly
        let micID = (includeAudio && config.microphoneEnabled && config.microphone?.isNone == false)
            ? config.microphone?.id : nil

        cameraBubble.show(shape: preferences.cameraBubbleShape,
                          size: preferences.cameraBubbleSize,
                          corner: preferences.cameraCorner)
        cameraBubble.setBackgroundMode(preferences.cameraBackground)
        cameraEngine.setCameraBackground(preferences.cameraBackground)

        let signature = "\(cameraID)|\(includeAudio)|\(micID ?? "-")"
        if cameraEngine.isRunning, previewSignature == signature { return }
        previewSignature = signature

        cameraEngine.startPreview(cameraID: cameraID,
                                  includeAudio: includeAudio,
                                  microphoneID: micID,
                                  previewLayer: cameraBubble.previewLayer,
                                  processedLayer: cameraBubble.processedLayer,
                                  mirrored: preferences.cameraMirrored,
                                  centerStage: preferences.centerStageEnabled,
                                  background: preferences.cameraBackground)
    }

    /// Applies a camera-background change from Settings to the live preview.
    func setCameraBackgroundLive(_ mode: CameraBackground) {
        cameraBubble.setBackgroundMode(mode)
        cameraEngine.setCameraBackground(mode)
    }

    /// Whether the currently selected camera supports Center Stage auto-framing,
    /// used to enable/disable the Settings switch.
    var selectedCameraSupportsCenterStage: Bool {
        guard config.camera?.isNone == false, let id = config.camera?.id,
              let device = AVCaptureDevice(uniqueID: id) else { return false }
        return device.formats.contains { $0.isCenterStageSupported }
    }

    /// Applies a Center Stage change from Settings to the live session immediately.
    func setCenterStageLive(_ on: Bool) {
        guard cameraEngine.isRunning else { return }
        cameraEngine.setCenterStage(on)
    }

    private func teardownCamera() {
        livePreviewActive = false
        previewSignature = nil
        captureIndicator.hide()
        cameraBubble.hide()
        cameraEngine.stopSession()
    }

    // MARK: Capture-region geometry

    private func captureRegionRect() -> NSRect? {
        switch config.mode {
        case .screen, .area:
            guard let displayID = config.display?.id else { return nil }
            if let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == displayID }) {
                return screen.frame
            }
            return NSScreen.main?.frame
        case .window:
            guard let window = config.window?.scWindow else { return nil }
            return Self.cocoaRect(fromCG: window.frame)
        case .cameraOnly:
            return nil
        }
    }

    private func captureRegionLabel() -> String {
        switch config.mode {
        case .window: return config.window?.appName ?? "Window"
        default:      return config.display?.name.components(separatedBy: " · ").first ?? "Screen"
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Converts a CoreGraphics global rect (top-left origin) to Cocoa screen
    /// coordinates (bottom-left origin), as used by `SCWindow.frame`.
    private static func cocoaRect(fromCG cg: CGRect) -> NSRect {
        let screens = NSScreen.screens
        let zero = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
        let height = zero?.frame.height ?? cg.maxY
        return NSRect(x: cg.minX, y: height - cg.maxY, width: cg.width, height: cg.height)
    }

    private func handleStreamError(_ error: Error) {
        guard isRecording || isCountingDown else { return }
        errorMessage = "Recording stopped: \(error.localizedDescription)"
        Task { await stop() }
    }

    // MARK: Timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: Sharing

    func share(_ recording: Recording) async {
        guard let fileURL = store.primaryMediaURL(for: recording) else {
            errorMessage = "Recording file is missing."
            return
        }
        let service = uploadSettings.makeService()

        var working = recording
        working.share = .uploading(progress: 0)
        store.upsert(working)
        uploadProgress[recording.id] = 0

        do {
            let url = try await service.upload(recording: recording, fileURL: fileURL) { [weak self] value in
                self?.uploadProgress[recording.id] = value
            }
            // Links are OFF by default: uploading puts the file in the cloud, but
            // the share link stays disabled until the owner enables it.
            working.share = .disabled(url: url)
            store.upsert(working)
            uploadProgress[recording.id] = nil
        } catch {
            working.share = .failed(reason: error.localizedDescription)
            store.upsert(working)
            uploadProgress[recording.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Re-renders a recording's `final.mp4` from its retained raw tracks with a
    /// new camera placement (post-record reposition/resize). Needs a stored plan
    /// + a camera track. The new media is composed in a temporary folder so a
    /// failed edit cannot destroy the existing final video.
    func recompose(_ recording: Recording, placement: CameraPlacement) async {
        guard isRecomposing == nil else {
            errorMessage = "Another recording is already being re-rendered."
            return
        }
        guard var plan = recording.plan else {
            errorMessage = "This recording predates post-edit support — re-record to enable it."
            return
        }
        guard let cameraName = recording.cameraFileName else {
            errorMessage = "No camera track to reposition."
            return
        }
        let folder = store.folderURL(for: recording.id)
        let screenURL = recording.screenFileName.map { folder.appendingPathComponent($0) }
        let cameraURL = folder.appendingPathComponent(cameraName)
        plan.cameraPlacement = placement
        let workFolder = folder.appendingPathComponent(".recompose-\(UUID().uuidString)", isDirectory: true)

        isRecomposing = recording.id
        defer { isRecomposing = nil }
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workFolder) }

            let output = try await VideoComposer.compose(
                screenURL: screenURL,
                cameraURL: cameraURL,
                bubbleShape: plan.bubbleShape,
                mirrored: plan.mirrored,
                cameraBackground: plan.cameraBackground,
                corner: plan.corner,
                padding: plan.padding,
                background: plan.background,
                aspectRatio: plan.aspectRatio.map { CGFloat($0) },
                fps: plan.fps ?? 30,
                cameraStartOffset: plan.cameraStartOffset,
                leadTrim: plan.leadTrim,
                cameraPlacement: plan.cameraPlacement,
                cameraHiddenRanges: plan.cameraHiddenRanges,
                screenPauseSpans: plan.screenPauseSpans,
                cameraPauseSpans: plan.cameraPauseSpans,
                outputURL: workFolder.appendingPathComponent("final.mp4")
            )

            let finalURL = folder.appendingPathComponent("final.mp4")
            try replaceFile(at: finalURL, with: output.url)
            if let audioURL = output.audioURL {
                try replaceFile(at: folder.appendingPathComponent("audio.m4a"), with: audioURL)
            }

            var working = recording
            working.plan = plan
            working.finalFileName = "final.mp4"
            if output.audioURL != nil { working.audioFileName = "audio.m4a" }
            working.width = Int(output.size.width)
            working.height = Int(output.size.height)
            working.thumbnailFileName = await generateThumbnail(for: recording.id, sourceURL: finalURL)
                ?? working.thumbnailFileName

            // The cloud copy is now stale. Only mark it local after confirmed
            // deletion; otherwise keep the truthful remote status and warn that
            // the old shared version still exists.
            var cloudWarning: String?
            if recording.shareURL != nil {
                if let backend = uploadSettings.cueBackendService() {
                    do {
                        try await backend.deleteRemote(recording: recording)
                        working.share = .local
                    } catch {
                        cloudWarning = "The edit was saved locally, but the previous cloud copy could not be removed: \(error.localizedDescription)"
                    }
                } else {
                    cloudWarning = "The edit was saved locally. The previous cloud copy is still online; switch to the Cue server backend to remove it, or re-upload the edit."
                }
            }
            store.upsert(working)
            if let cloudWarning { errorMessage = cloudWarning }
        } catch {
            errorMessage = "Re-render failed: \(error.localizedDescription)"
        }
    }

    private func replaceFile(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    private func generateThumbnail(for id: UUID, sourceURL: URL) async -> String? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        do {
            let image = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
                return nil
            }
            try data.write(to: store.folderURL(for: id).appendingPathComponent("thumb.jpg"), options: .atomic)
            return "thumb.jpg"
        } catch {
            return nil
        }
    }

    /// Relaunches the app — needed for macOS to re-evaluate a freshly granted
    /// Screen Recording permission for the running process.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func copyLink(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func revealInFinder(_ recording: Recording) {
        guard let url = store.primaryMediaURL(for: recording) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Library window (AppKit-managed, since the menu bar item is too)

    private var libraryWindow: NSWindow?

    func openLibrary() {
        if libraryWindow == nil {
            let hosting = NSHostingController(rootView: LibraryView().environmentObject(self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Cue Library"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 960, height: 640))
            window.contentMinSize = NSSize(width: 760, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    func delete(_ recording: Recording) {
        // Remove the cloud copy too, if shared, so no dangling link/object remains.
        if recording.shareURL != nil, let backend = uploadSettings.cueBackendService() {
            Task { try? await backend.deleteRemote(recording: recording) }
        }
        store.delete(recording)
    }

    /// Owner: remove the cloud copy but keep the local recording so it can be
    /// re-uploaded later. The share link stops resolving until re-shared.
    func removeFromCloud(_ recording: Recording) async {
        guard let backend = uploadSettings.cueBackendService() else {
            errorMessage = "Switch sharing to “Cue server” to manage cloud copies."
            return
        }
        do {
            try await backend.deleteRemote(recording: recording)
            var working = recording
            working.share = .local
            store.upsert(working)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Owner: disable or re-enable the public share link without deleting bytes.
    func setShareDisabled(_ recording: Recording, disabled: Bool) async {
        guard let url = recording.shareURL else { return }
        guard let backend = uploadSettings.cueBackendService() else {
            errorMessage = "Switch sharing to “Cue server” to manage share links."
            return
        }
        do {
            try await backend.setShareDisabled(disabled, recording: recording)
            var working = recording
            working.share = disabled ? .disabled(url: url) : .shared(url: url)
            store.upsert(working)
            if !disabled {
                lastShareURL = url
                copyLink(url.absoluteString)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension TimeInterval {
    /// Formats seconds as `m:ss` (or `h:mm:ss` past an hour).
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
