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
    /// Owned here, not by the settings view: the popover closes (and its views
    /// are torn down) the moment the setup flow opens the browser, and the
    /// in-flight setup state must survive that.
    let cloudflareSetup = CloudflareProvisioner()
    /// Onboarding progress lives here for the same reason — the Cloudflare
    /// step opens the browser, which closes the popover mid-flow.
    @Published var onboardingStep: OnboardingStep = .intro
    let preferences = Preferences()
    let overlay = OverlayController()
    let cameraEngine = CameraEngine()
    let cameraBubble = CameraBubbleController()
    let captureIndicator = CaptureRegionIndicator()
    let regionPicker = ScreenRegionPicker()
    let micLevel = MicLevelMonitor()
    /// The floating script panel. Excluded from capture like every other Cue
    /// window, so it's visible to the presenter but never in the video.
    let teleprompter = TeleprompterController()
    let captionGenerator = CaptionGenerator()
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

    enum InsightGenerationPhase: Equatable {
        case uploading
        case transcribing
        case summarizing
        case syncing

        var title: String {
            switch self {
            case .uploading: return "Uploading privately…"
            case .transcribing: return "Transcribing…"
            case .summarizing: return "Summarizing…"
            case .syncing: return "Refreshing…"
            }
        }
    }

    /// Per-recording AI work shown inline in the Library detail pane.
    @Published private(set) var insightGeneration: [UUID: InsightGenerationPhase] = [:]

    /// Whole-library metadata reconciliation. Cue performs this on launch and
    /// periodically thereafter so web edits appear without a manual refresh.
    @Published private(set) var isLibrarySyncing = false
    @Published private(set) var lastLibrarySyncAt: Date?

    // In-recording controls (mic mute / camera off / pause)
    @Published private(set) var isPaused = false
    @Published private(set) var micActive = true
    @Published private(set) var cameraActive = true

    /// Whether the popover is currently showing the Settings screen.
    @Published var showSettings = false

    /// Selected settings tab. Lives here rather than view `@State` so the
    /// choice survives popover teardowns — e.g. mid Cloudflare setup, which
    /// opens the browser and closes the popover.
    @Published var settingsTab: SettingsTab = .recording

    // Sharing / library surface
    @Published var uploadProgress: [UUID: Double] = [:]
    /// Id of the recording currently being re-rendered (post-record studio edit).
    @Published var isRecomposing: UUID?
    @Published var lastShareURL: URL?
    @Published var justFinished: Recording?
    @Published var errorMessage: String?

    /// Whether the script panel was actually up for the take being recorded, so
    /// only those recordings keep the script as notes.
    private var usedTeleprompter = false

    private var elapsedTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    private var captureReady = false
    private var countdownFinished = false
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
                          preferences.objectWillChange,
                          micLevel.objectWillChange,
                          teleprompter.objectWillChange,
                          captionGenerator.objectWillChange] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.syncLibrary() }
            }
            .store(in: &cancellables)

        Task { @MainActor [weak self] in
            await self?.resumeInterruptedUploads()
            await self?.syncLibrary()
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

        micLevel.stop()
        startCameraPreviewIfNeeded()
        overlay.show(appState: self)
        if preferences.creativeModeEnabled && !preferences.scriptDraft.isEmpty {
            teleprompter.show(appState: self, mode: .editing)
        }
        // Covers the panel being opened by hand as well as automatically.
        usedTeleprompter = teleprompter.isVisible

        let seconds = config.countdownSeconds
        captureReady = false
        countdownFinished = seconds <= 0
        state = seconds > 0 ? .countdown(seconds) : .recording

        // Begin capturing IMMEDIATELY — both the screen and the camera roll
        // throughout the countdown so they're fully warmed up and frame-locked
        // before the content begins. The countdown lead-in is trimmed off in the
        // composer (`markContentStart`), so the final clip starts cleanly with
        // both streams already present and in sync — no camera "gap" at the head.
        captureStartTask = Task { [weak self] in
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
                                            fps: self.preferences.captureFPS,
                                            cinematicEffects: self.preferences.cinematicEffectsEnabled,
                                            creativeLayout: self.preferences.creativeModeEnabled
                                                ? self.preferences.creativeLayout : nil,
                                            screenRegion: self.canChooseScreenRegion
                                                ? self.preferences.creativeScreenRegion : nil)
                self.captureStartTask = nil
                self.captureReady = true
                self.enterRecordingIfReady()
            } catch {
                self.captureStartTask = nil
                self.errorMessage = error.localizedDescription
                self.state = .idle
                self.overlay.hide()
                self.teleprompter.hide()
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
                self.countdownFinished = true
                self.enterRecordingIfReady()
            }
        }
    }

    private func enterRecordingIfReady() {
        guard captureReady, countdownFinished else { return }
        enterRecording()
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
        // The script stops being something to edit and becomes something to
        // read; auto-scroll starts here, in step with content-start.
        if teleprompter.isVisible {
            teleprompter.setMode(.prompting, autoScroll: preferences.teleprompterAutoScroll)
        }
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

    func stop(shareAfter: Bool = true) async {
        countdownTask?.cancel()
        countdownTask = nil
        stopElapsedTimer()

        // `RecordingEngine.start` crosses async ScreenCaptureKit boundaries.
        // Let that setup settle before stop/cancel touches the same writers so a
        // very fast Stop or Quit cannot interleave teardown with initialization.
        if let startTask = captureStartTask {
            startTask.cancel()
            await startTask.value
            captureStartTask = nil
        }

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
            teleprompter.hide()
            // `engine.stop` releases the camera device (green light off) as soon
            // as the raw tracks are written, not after the whole composition.
            var recording = await engine.stop { [weak self] in
                self?.cameraEngine.stopSession()
                self?.livePreviewActive = false
                self?.previewSignature = nil
            }
            // Only the takes actually read from the script keep it. The draft
            // outlives a session by design, so stamping it on unconditionally
            // would attach it to every later screencast too.
            if var finished = recording, usedTeleprompter, !preferences.scriptDraft.isEmpty {
                finished.notes = preferences.scriptDraft
                finished.notesUpdatedAt = .now
                store.upsert(finished)
                recording = finished
            }
            usedTeleprompter = false
            // Captions are burned in before sharing, so the copy that goes to
            // the cloud is the one people actually watch.
            if let finished = recording, shouldCaption(finished) {
                recording = await generateCaptions(for: finished) ?? finished
            }
            state = .idle
            if let recording {
                justFinished = recording
                if shareAfter { await share(recording) }
            }
        case .countdown:
            // Capture is already rolling during the countdown — discard it.
            state = .idle
            usedTeleprompter = false
            await engine.cancel()
            overlay.hide()
            teleprompter.hide()
            teardownCamera()
        default:
            state = .idle
            usedTeleprompter = false
            overlay.hide()
            teleprompter.hide()
            teardownCamera()
        }
    }

    // MARK: Captions

    /// Opens the overlay for choosing which 9:16 slice of the screen a vertical
    /// recording frames. Only meaningful for display capture — a window is
    /// already its own frame.
    func chooseScreenRegion() {
        guard let screen = captureScreen() else { return }
        regionPicker.pick(on: screen, initial: preferences.creativeScreenRegion) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                break
            case let .saved(region):
                self.apply(region)
            case let .record(region):
                // Choosing the area closes the popover, so there'd be nothing
                // left to press Record in — go straight into the countdown.
                self.apply(region)
                self.start()
            }
        }
    }

    private func apply(_ region: ScreenRegion) {
        preferences.creativeScreenRegion = region
        updateCaptureIndicator()
    }

    /// Clears the chosen area, going back to the middle of the screen.
    func clearScreenRegion() {
        preferences.creativeScreenRegion = nil
        updateCaptureIndicator()
    }

    /// Whether choosing an area applies to what is currently selected.
    var canChooseScreenRegion: Bool {
        preferences.creativeModeEnabled
            && preferences.creativeLayout == .screenFill
            && config.mode == .screen
    }

    /// Prompts for speech access if it has never been asked for, at a moment
    /// when nothing is recording. Captions default to on, so the prompt has to
    /// be driven by turning Creative Mode on as well as by the captions switch
    /// itself — otherwise nobody ever crosses an off-to-on edge and the request
    /// is never made.
    func ensureSpeechPermission() {
        guard preferences.captionsEnabled,
              permissions.speechRecognition == .notDetermined else { return }
        Task { await permissions.requestSpeechRecognition() }
    }

    /// Opens the pane where speech access can be switched back on. Cue only
    /// appears in that list once it has asked at least once, which is why
    /// `ensureSpeechPermission` matters before ever pointing anyone here.
    func openSpeechRecognitionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the pane holding the input volume slider — the setting behind most
    /// recordings that come out too quiet to caption.
    func openSoundInputSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether a just-finished recording should get captions without being asked.
    private func shouldCaption(_ recording: Recording) -> Bool {
        preferences.creativeModeEnabled && preferences.captionsEnabled
            && recording.plan != nil && recording.finalFileName != nil
    }

    /// Transcribes and burns captions into a recording's video. Failures are
    /// reported but never block the recording itself — a video without captions
    /// is far better than no video.
    @discardableResult
    func generateCaptions(for recording: Recording) async -> Recording? {
        guard recording.plan != nil else {
            errorMessage = "Cue can't add captions to this recording — it was made before captions existed. Record a new one to use them."
            return nil
        }
        let locale = preferences.captionLocaleIdentifier.map(Locale.init(identifier:))
            ?? TranscriptionService.preferredLocale()
        do {
            return try await captionGenerator.generate(
                for: recording,
                style: preferences.captionStyle,
                locale: locale,
                store: store,
                render: { [weak self] recording, plan in
                    await self?.recompose(recording, plan: plan)
                }
            )
        } catch {
            NSLog("Cue caption generation failed: \(error)")
            // Transcribing asks for speech access on demand, so the cached
            // status may be out of date now.
            permissions.refresh()
            // Cue's own failures are written for people to read; anything else
            // would put a raw system string in front of the user.
            errorMessage = (error as? CaptionGenerator.Failure)?.errorDescription
                ?? "Cue couldn't add captions to this recording. The video was saved without them."
            return nil
        }
    }

    /// Gives active capture/composition a chance to finish before the process
    /// exits. Uploads are independently checkpointed and can resume next launch,
    /// so quitting never waits on the network.
    func prepareForTermination() async {
        if isRecording || isCountingDown {
            await stop(shareAfter: false)
        }
        while state == .processing {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func cancelCountdown() {
        Task { await stop(shareAfter: false) }
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
        startMicMonitorIfNeeded()
    }

    /// Called when the popover closes. Tears the preview down only if we're idle;
    /// once a countdown/recording is under way the camera must keep running.
    func popoverDidDisappear() {
        guard state == .idle else { return }
        micLevel.stop()
        teardownCamera()
    }

    /// Shows the input level for the chosen microphone while the popover is
    /// open, so a microphone that isn't hearing anything is obvious before a
    /// recording rather than after it.
    func startMicMonitorIfNeeded() {
        guard state == .idle, livePreviewActive else { return }
        guard config.microphoneEnabled, config.microphone?.isNone == false,
              let id = config.microphone?.id else {
            micLevel.stop()
            return
        }
        // Onboarding is the only other place that asks, so anyone who skipped it
        // would otherwise reach Record having never been prompted.
        if permissions.microphone == .notDetermined {
            Task { [weak self] in
                await self?.permissions.requestMicrophone()
                // The popover may have closed, or a recording started, while
                // the system prompt was up — go back through the checks above
                // rather than claiming the device behind capture's back.
                self?.startMicMonitorIfNeeded()
            }
            return
        }
        micLevel.start(deviceID: id)
    }

    /// Called when the source/camera selection changes while the popover is open,
    /// so the indicator and camera preview track the current configuration.
    func liveSelectionChanged() {
        guard state == .idle, livePreviewActive else { return }
        updateCaptureIndicator()
        startMicMonitorIfNeeded()
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

    private func captureScreen() -> NSScreen? {
        guard let displayID = config.display?.id else { return NSScreen.main }
        return NSScreen.screens.first { Self.displayID(of: $0) == displayID } ?? NSScreen.main
    }

    private func captureRegionRect() -> NSRect? {
        switch config.mode {
        case .screen:
            guard let screen = captureScreen() else { return nil }
            guard canChooseScreenRegion, let region = preferences.creativeScreenRegion else {
                return screen.frame
            }
            // The region is stored top-left origin; NSScreen frames run bottom-up.
            let f = screen.frame
            return NSRect(x: f.minX + region.x * f.width,
                          y: f.minY + (1 - region.y - region.height) * f.height,
                          width: region.width * f.width,
                          height: region.height * f.height)
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

    func share(_ recording: Recording, using backend: UploadBackend? = nil) async {
        guard uploadProgress[recording.id] == nil else { return }
        guard let fileURL = store.primaryMediaURL(for: recording) else {
            errorMessage = "Recording file is missing."
            return
        }
        let selectedBackend = backend ?? uploadSettings.backend
        let service = uploadSettings.makeService(for: selectedBackend)

        var working = latestRecording(recording.id) ?? recording
        working.share = .uploading(progress: 0)
        working.uploadBackend = selectedBackend
        guard store.upsert(working) else {
            errorMessage = "The upload was not started because Cue could not save its recovery state."
            return
        }
        uploadProgress[recording.id] = 0

        do {
            if let earlyURL = try await service.prepare(recording: working, fileURL: fileURL) {
                working.preparedShareURL = earlyURL
                store.upsert(working)
                lastShareURL = earlyURL
                copyLink(earlyURL.absoluteString)
            }
            let url = try await service.upload(recording: working, fileURL: fileURL) { [weak self] value in
                self?.uploadProgress[recording.id] = value
            }
            working.preparedShareURL = nil
            working.share = service.linksArePublicOnUpload ? .shared(url: url) : .disabled(url: url)
            working.uploadBackend = selectedBackend
            guard store.upsert(working) else {
                // Leave the durable `.uploading` state and object-completion
                // receipt intact. Relaunch can finalize metadata without sending
                // the media again once the Library index is writable.
                uploadProgress[recording.id] = nil
                errorMessage = "The recording was uploaded, but Cue could not save the completed state. It will retry safely next launch."
                return
            }
            service.confirmUploadPersisted(recording: working, fileURL: fileURL)
            uploadProgress[recording.id] = nil
            lastShareURL = url
            if service.linksArePublicOnUpload { copyLink(url.absoluteString) }
        } catch {
            working.share = .failed(reason: error.localizedDescription)
            working.uploadBackend = selectedBackend
            store.upsert(working)
            uploadProgress[recording.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    /// A process exit can interrupt an async URLSession without executing its
    /// catch block, leaving a truthful `.uploading` marker in the atomic index.
    /// Retry those entries on launch; multipart checkpoints skip completed parts.
    private func resumeInterruptedUploads() async {
        let interrupted = store.recordings.filter {
            if case .uploading = $0.share { return true }
            return false
        }
        for recording in interrupted {
            await share(recording, using: recording.uploadBackend)
        }
    }

    // MARK: AI insights

    /// Generates and stores a transcript from the Library. A local-only
    /// recording is uploaded to the configured Cue server first with its public
    /// link disabled, so this never requires opening the web dashboard.
    func generateTranscript(_ recording: Recording) async {
        guard insightGeneration[recording.id] == nil else { return }
        do {
            let backend = try nativeInsightsBackend()
            insightGeneration[recording.id] = needsCueUpload(recording) ? .uploading : .transcribing
            defer { insightGeneration[recording.id] = nil }

            let prepared = try await prepareForInsights(recording, using: backend)
            insightGeneration[recording.id] = .transcribing
            let result = try await backend.transcribe(recording: prepared)

            var working = latestRecording(recording.id) ?? prepared
            working.transcript = result.text
            working.transcriptVTT = result.vtt
            working.transcriptUpdatedAt = result.updatedAt ?? .now
            store.upsert(working)
        } catch {
            insightGeneration[recording.id] = nil
            errorMessage = "Transcript generation failed: \(error.localizedDescription)"
        }
    }

    /// Generates a summary and then syncs the server-side transcript produced
    /// along the way, so both tabs are immediately available in the Library.
    func generateSummary(_ recording: Recording) async {
        guard insightGeneration[recording.id] == nil else { return }
        do {
            let backend = try nativeInsightsBackend()
            insightGeneration[recording.id] = needsCueUpload(recording) ? .uploading : .summarizing
            defer { insightGeneration[recording.id] = nil }

            let prepared = try await prepareForInsights(recording, using: backend)
            insightGeneration[recording.id] = .summarizing
            let insight = try await backend.summarize(recording: prepared)
            let remote = try? await backend.fetchInsights(recording: prepared)

            var working = latestRecording(recording.id) ?? prepared
            if let remote {
                working = applyRemote(remote, to: working)
            } else {
                working.title = insight.title
                working.summary = insight.summary
            }
            store.upsert(working)
        } catch {
            insightGeneration[recording.id] = nil
            errorMessage = "Summary generation failed: \(error.localizedDescription)"
        }
    }

    /// Pulls insights that may have been generated previously on the web.
    func refreshInsights(_ recording: Recording) async {
        guard insightGeneration[recording.id] == nil else { return }
        do {
            let backend = try nativeInsightsBackend()
            guard !needsCueUpload(recording) else {
                throw UploadError.notConfigured("upload this recording before refreshing insights")
            }
            insightGeneration[recording.id] = .syncing
            defer { insightGeneration[recording.id] = nil }

            let remote = try await backend.fetchInsights(recording: recording)
            let local = latestRecording(recording.id) ?? recording
            store.upsert(try await reconcile(local, with: remote, using: backend))
        } catch {
            insightGeneration[recording.id] = nil
            errorMessage = "Couldn’t refresh insights: \(error.localizedDescription)"
        }
    }

    private func nativeInsightsBackend() throws -> CueBackendUploadService {
        guard uploadSettings.backend == .cueServer,
              !uploadSettings.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !uploadSettings.ownerToken.isEmpty,
              let backend = uploadSettings.cueBackendService() else {
            throw UploadError.notConfigured("choose Cue server and add its owner token in Settings")
        }
        return backend
    }

    private func needsCueUpload(_ recording: Recording) -> Bool {
        recording.uploadBackend != .cueServer || recording.shareURL == nil
    }

    private func latestRecording(_ id: UUID) -> Recording? {
        store.recordings.first { $0.id == id }
    }

    /// Reconciles every native/cloud pair. Newer per-field values are pushed;
    /// newer web values are pulled. Cloud deletions only detach the remote copy
    /// and never delete the user's local media.
    func syncLibrary(showErrors: Bool = false) async {
        guard !isLibrarySyncing,
              uploadSettings.backend == .cueServer,
              !uploadSettings.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !uploadSettings.ownerToken.isEmpty,
              let backend = uploadSettings.cueBackendService() else { return }

        isLibrarySyncing = true
        defer { isLibrarySyncing = false }
        do {
            let remotes = try await backend.fetchLibrary()
            let remoteByID = Dictionary(uniqueKeysWithValues: remotes.compactMap { remote in
                UUID(uuidString: remote.id).map { ($0, remote) }
            })
            let localIDs = store.recordings.map(\.id)

            for id in localIDs {
                guard let local = latestRecording(id) else { continue }
                if let remote = remoteByID[id] {
                    let settled = try await reconcile(local, with: remote, using: backend)
                    if settled != local { store.upsert(settled) }
                } else if local.uploadBackend == .cueServer {
                    var detached = local
                    detached.share = .local
                    detached.uploadBackend = nil
                    store.upsert(detached)
                }
            }
            lastLibrarySyncAt = .now
        } catch {
            if showErrors {
                errorMessage = "Library sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func reconcile(
        _ local: Recording,
        with fetchedRemote: CueRemoteRecording,
        using backend: CueBackendUploadService
    ) async throws -> Recording {
        var remote = fetchedRemote
        var fields: Set<CueMetadataField> = []
        if local.title != remote.title,
           isNewer(local.titleUpdatedAt, than: remote.titleUpdatedAt) {
            fields.insert(.title)
        }
        if (local.transcript != remote.transcript || local.transcriptVTT != remote.transcriptVTT),
           isNewer(local.transcriptUpdatedAt, than: remote.transcriptUpdatedAt) {
            fields.insert(.transcript)
        }
        if local.summary != remote.summary,
           isNewer(local.summaryUpdatedAt, than: remote.summaryUpdatedAt) {
            fields.insert(.summary)
        }
        if !fields.isEmpty {
            remote = try await backend.syncMetadata(recording: local, fields: fields)
        }
        return applyRemote(remote, to: local)
    }

    private func applyRemote(_ remote: CueRemoteRecording, to local: Recording) -> Recording {
        var working = local

        if local.title == remote.title {
            working.titleUpdatedAt = newest(local.titleUpdatedAt, remote.titleUpdatedAt)
        } else {
            working.title = remote.title
            working.titleUpdatedAt = remote.titleUpdatedAt
        }

        if local.transcript == remote.transcript && local.transcriptVTT == remote.transcriptVTT {
            working.transcriptUpdatedAt = newest(local.transcriptUpdatedAt, remote.transcriptUpdatedAt)
        } else {
            working.transcript = remote.transcript
            working.transcriptVTT = remote.transcriptVTT
            working.transcriptUpdatedAt = remote.transcriptUpdatedAt
        }

        if local.summary == remote.summary {
            working.summaryUpdatedAt = newest(local.summaryUpdatedAt, remote.summaryUpdatedAt)
        } else {
            working.summary = remote.summary
            working.summaryUpdatedAt = remote.summaryUpdatedAt
        }

        if let url = remote.shareURL {
            switch remote.uploadStatus {
            case "uploading":
                working.preparedShareURL = url
                working.share = .uploading(progress: uploadProgress[local.id] ?? 0)
                working.uploadBackend = .cueServer
                return working
            case "failed":
                working.preparedShareURL = url
                working.share = .failed(reason: "The previous upload did not finish.")
                working.uploadBackend = .cueServer
                return working
            default:
                working.preparedShareURL = nil
                working.share = (remote.disabled ?? false) ? .disabled(url: url) : .shared(url: url)
            }
        }
        working.uploadBackend = .cueServer
        return working
    }

    private func isNewer(_ local: Date?, than remote: Date?) -> Bool {
        guard let local else { return false }
        guard let remote else { return true }
        return local > remote
    }

    private func newest(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Renames a recording locally and mirrors the change to the Cue server when
    /// this recording has a registered cloud copy. Local edits remain saved if a
    /// temporarily unavailable server cannot be updated.
    func rename(_ recording: Recording, to proposedTitle: String) async {
        let collapsed = proposedTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let title = String(collapsed.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "A recording title can’t be empty."
            return
        }

        var working = latestRecording(recording.id) ?? recording
        working.title = title
        working.titleUpdatedAt = .now
        store.upsert(working)

        guard working.uploadBackend == .cueServer, working.shareURL != nil else { return }
        guard let backend = uploadSettings.cueBackendService() else {
            errorMessage = "The title was saved on this Mac, but Cue server is not configured to update the web copy."
            return
        }
        do {
            let remoteTitle = try await backend.updateTitle(title, recording: working)
            working.title = remoteTitle
            store.upsert(working)
        } catch {
            errorMessage = "The title was saved on this Mac, but the web copy could not be updated: \(error.localizedDescription)"
        }
    }

    private func prepareForInsights(
        _ recording: Recording,
        using backend: CueBackendUploadService
    ) async throws -> Recording {
        if !needsCueUpload(recording) { return latestRecording(recording.id) ?? recording }
        guard let fileURL = store.primaryMediaURL(for: recording) else {
            throw UploadError.fileMissing
        }

        var working = latestRecording(recording.id) ?? recording
        working.share = .uploading(progress: 0)
        working.uploadBackend = .cueServer
        guard store.upsert(working) else {
            throw UploadError.invalidUploadState("Cue could not save the private upload recovery state.")
        }
        uploadProgress[recording.id] = 0
        defer { uploadProgress[recording.id] = nil }

        do {
            let url = try await backend.upload(recording: working, fileURL: fileURL) { [weak self] value in
                self?.uploadProgress[recording.id] = value
            }
            working.preparedShareURL = nil
            working.share = .disabled(url: url)
            working.uploadBackend = .cueServer
            guard store.upsert(working) else {
                throw UploadError.invalidUploadState("The upload finished, but Cue could not save its completed state.")
            }
            backend.confirmUploadPersisted(recording: working, fileURL: fileURL)
            return working
        } catch {
            working.share = .failed(reason: error.localizedDescription)
            working.uploadBackend = .cueServer
            store.upsert(working)
            throw error
        }
    }

    /// Re-renders a recording's `final.mp4` from its retained raw tracks with an
    /// edited plan (camera reposition, Creative Mode layout, burned-in
    /// captions). Needs a stored plan. The new media is composed in a temporary
    /// folder so a failed edit cannot destroy the existing final video.
    @discardableResult
    func recompose(_ recording: Recording, plan: CompositionPlan) async -> Recording? {
        guard isRecomposing == nil else {
            errorMessage = "Another recording is already being re-rendered."
            return nil
        }
        guard recording.plan != nil else {
            errorMessage = "This recording predates post-edit support — re-record to enable it."
            return nil
        }
        let folder = store.folderURL(for: recording.id)
        let screenURL = recording.screenFileName.map { folder.appendingPathComponent($0) }
        let cameraURL = recording.cameraFileName.map { folder.appendingPathComponent($0) }

        let mouseActivity: MouseActivity? = {
            guard plan.cinematicEffectsEnabled == true, let name = plan.activityFileName,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(MouseActivity.self, from: data)
        }()
        let captions: [CaptionCue] = {
            guard plan.burnsCaptions else { return [] }
            let name = plan.captionsFileName ?? CaptionTrack.fileName
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let track = try? JSONDecoder.cue.decode(CaptionTrack.self, from: data) else { return [] }
            return track.cues
        }()
        if recording.cameraFileName == nil && mouseActivity == nil && captions.isEmpty && !plan.isCreative {
            errorMessage = "This recording has no editable camera, captions, or pointer activity."
            return nil
        }
        let workFolder = folder.appendingPathComponent(".recompose-\(UUID().uuidString)", isDirectory: true)

        isRecomposing = recording.id
        defer { isRecomposing = nil }
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workFolder) }

            let output = try await VideoComposer.compose(
                plan: plan,
                screenURL: screenURL,
                cameraURL: cameraURL,
                mouseActivity: mouseActivity,
                captions: captions,
                outputURL: workFolder.appendingPathComponent("final.mp4")
            )

            let finalURL = folder.appendingPathComponent("final.mp4")
            try replaceFile(at: finalURL, with: output.url)
            if let audioURL = output.audioURL {
                try replaceFile(at: folder.appendingPathComponent("audio.m4a"), with: audioURL)
            }

            // Re-read the record before writing: the editor holds the copy it
            // opened with, and a title, transcript or note edited in the Library
            // since then must not be rolled back by this render.
            var working = latestRecording(recording.id) ?? recording
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
            if working.shareURL != nil {
                if let backend = uploadSettings.cueBackendService() {
                    do {
                        try await backend.deleteRemote(recording: working)
                        working.share = .local
                        working.uploadBackend = nil
                    } catch {
                        NSLog("Cue remote delete after re-render failed: \(error.localizedDescription)")
                        cloudWarning = "Your edit was saved, but the shared copy couldn't be taken down. The old version is still online — try sharing again to replace it."
                    }
                } else {
                    cloudWarning = "Your edit was saved. The shared copy is still the old version — upload it again to replace it."
                }
            }
            store.upsert(working)
            if let cloudWarning { errorMessage = cloudWarning }
            return working
        } catch {
            NSLog("Cue re-render failed: \(error.localizedDescription)")
            errorMessage = "Cue couldn't finish re-rendering this recording. Your original video is untouched."
            return nil
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
        Task { await syncLibrary() }
    }

    // MARK: Creative editor window

    private var editorWindow: NSWindow?
    private var editorModel: CreativeEditorModel?

    /// Opens the vertical-video editor for a recording. One window is reused;
    /// opening a different recording replaces its contents.
    func openEditor(for recording: Recording) {
        guard recording.plan != nil else {
            errorMessage = "This recording predates post-edit support — re-record to enable it."
            return
        }
        // Release the previous preview's player before building the next one.
        editorModel?.teardown()
        let model = CreativeEditorModel(recording: recording, app: self)
        editorModel = model

        let hosting = NSHostingController(rootView: CreativeEditorView(model: model)
            .environmentObject(self))
        if let window = editorWindow {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 700))
            window.contentMinSize = NSSize(width: 720, height: 560)
            window.isReleasedWhenClosed = false
            window.center()
            editorWindow = window
        }
        editorWindow?.title = "Creative Editor — \(recording.title)"
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
        Task { await model.load() }
    }

    func delete(_ recording: Recording) {
        do {
            // Keep local deletion recoverable. The Finder Trash is emptied only
            // when the user explicitly chooses to do so.
            try store.delete(recording)
        } catch {
            errorMessage = "Couldn’t move the recording to Trash: \(error.localizedDescription)"
            return
        }
        // Remove the cloud copy too, if shared, so no dangling link/object remains.
        if recording.shareURL != nil, let backend = uploadSettings.cueBackendService() {
            Task {
                do { try await backend.deleteRemote(recording: recording) }
                catch {
                    await MainActor.run {
                        self.errorMessage = "The local recording is in Trash, but the cloud copy could not be removed: \(error.localizedDescription)"
                    }
                }
            }
        }
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
            working.uploadBackend = nil
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
