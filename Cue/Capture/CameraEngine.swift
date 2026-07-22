import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import QuartzCore

/// Owns a single `AVCaptureSession` shared by the live camera-bubble preview
/// and the camera file recording, so the same device feeds both. The camera is
/// written to its own `camera.mov` (Option A separate tracks); audio is only
/// included in camera-only mode (otherwise it comes from the screen stream).
final class CameraEngine: NSObject, AVCaptureFileOutputRecordingDelegate,
                          AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// Exposed so the bubble's `AVCaptureVideoPreviewLayer` can attach.
    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.max.Cue.CameraEngine")

    // Live background replacement: a video data output feeds frames to a Vision
    // matte, and the composited result is pushed into the bubble's processed
    // layer. The raw camera is still recorded by `movieOutput` (the final clip's
    // background is applied by the offline compositor), so this is preview-only.
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.max.Cue.CameraProcessing")
    private let matte = CameraMatte(quality: .fast)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Live preview is throttled to this rate — a self-view doesn't need 30fps,
    /// and segmentation runs continuously while the popover is open.
    private let previewFrameInterval: CFTimeInterval = 1.0 / 20.0
    // The next four are read/written only on `processingQueue`.
    private var cameraBackground: CameraBackground = .none
    private var previewMirrored = false
    private var attachedProcessedLayer: CALayer?
    private var lastPreviewFrameTime: CFTimeInterval = 0
    private var stopContinuation: CheckedContinuation<Void, Never>?
    /// Held strongly until `stopSession` detaches it on the session queue, so the
    /// layer never tears its session connection down on the main thread.
    private var attachedPreviewLayer: AVCaptureVideoPreviewLayer?
    /// The camera device currently feeding the session, so live toggles (e.g.
    /// Center Stage) can reconfigure it without a full restart.
    private var currentCamera: AVCaptureDevice?

    /// Host-clock time (CACurrentMediaTime) when file recording actually began,
    /// used to align the camera track with the screen/audio timeline.
    private(set) var recordingStartAnchor: CFTimeInterval?

    var isRunning: Bool { session.isRunning }

    // MARK: Preview / session

    /// Configures the session, wires the preview layer, applies mirroring, and
    /// starts running — all on the serial session queue so nothing touches the
    /// (non-thread-safe) AVCaptureSession concurrently. The `previewLayer` is
    /// created on the main thread by the bubble and passed in here.
    func startPreview(cameraID: String,
                      includeAudio: Bool,
                      microphoneID: String?,
                      previewLayer: AVCaptureVideoPreviewLayer?,
                      processedLayer: CALayer?,
                      mirrored: Bool,
                      centerStage: Bool,
                      background: CameraBackground) {
        processingQueue.async { [weak self] in
            self?.cameraBackground = background
            self?.previewMirrored = mirrored
            self?.attachedProcessedLayer = processedLayer
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configure(cameraID: cameraID, includeAudio: includeAudio,
                           microphoneID: microphoneID, centerStage: centerStage)
            if let previewLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                previewLayer.session = self.session
                if let connection = previewLayer.connection {
                    connection.automaticallyAdjustsVideoMirroring = false
                    if connection.isVideoMirroringSupported {
                        connection.isVideoMirrored = mirrored
                    }
                }
                CATransaction.commit()
                self.attachedPreviewLayer = previewLayer
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure(cameraID: String, includeAudio: Bool, microphoneID: String?, centerStage: Bool) {
        session.beginConfiguration()
        let existingInputs = session.inputs
        existingInputs.forEach { session.removeInput($0) }
        session.sessionPreset = .high
        currentCamera = nil

        if let camera = AVCaptureDevice(uniqueID: cameraID),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.addInput(input)
            currentCamera = camera
            Self.enableContinuousFocus(on: camera)
            Self.applyCenterStage(centerStage, on: camera)
        }

        if includeAudio {
            let mic = microphoneID.flatMap { AVCaptureDevice(uniqueID: $0) }
                ?? AVCaptureDevice.default(for: .audio)
            if let mic, let audioInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
        }

        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        // Frames for the live background processing. Best-effort: if it can't be
        // added the preview falls back to the raw camera (recording unaffected).
        if !session.outputs.contains(videoDataOutput) {
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: processingQueue)
            if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
        }
        session.commitConfiguration()
    }

    /// Turns on continuous ("dynamic") autofocus when the device supports it — a
    /// no-op on fixed-focus or system-managed cameras, so we never force an
    /// unsupported mode. (Face-driven AF is iOS-only and managed by the system
    /// on macOS Continuity Cameras.)
    private static func enableContinuousFocus(on device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        } catch {
            NSLog("Cue: couldn't enable continuous focus — \(error.localizedDescription)")
        }
    }

    /// Changes the live background-replacement mode (from the Settings picker).
    func setCameraBackground(_ mode: CameraBackground) {
        processingQueue.async { [weak self] in self?.cameraBackground = mode }
    }

    /// Toggles Center Stage on the live session without a full restart (used by
    /// the Settings switch). A no-op if the camera doesn't support it.
    func setCenterStage(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.currentCamera else { return }
            self.session.beginConfiguration()
            Self.applyCenterStage(enabled, on: camera)
            self.session.commitConfiguration()
        }
    }

    /// Enables/disables Center Stage auto-framing when the device supports it (a
    /// no-op otherwise). Center Stage is a global, app-controlled feature, so we
    /// take app control before toggling it, and switch to a Center Stage-capable
    /// active format (closest to the current resolution) so it actually engages.
    private static func applyCenterStage(_ enabled: Bool, on device: AVCaptureDevice) {
        guard device.formats.contains(where: { $0.isCenterStageSupported }) else { return }
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = enabled
        guard enabled, !device.activeFormat.isCenterStageSupported else { return }
        let targetArea = dimensionArea(device.activeFormat)
        guard let best = device.formats
            .filter({ $0.isCenterStageSupported })
            .min(by: { abs(dimensionArea($0) - targetArea) < abs(dimensionArea($1) - targetArea) }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            NSLog("Cue: couldn't select a Center Stage format — \(error.localizedDescription)")
        }
    }

    private static func dimensionArea(_ format: AVCaptureDevice.Format) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(d.width) * Int(d.height)
    }

    // MARK: Recording

    func beginRecording(to url: URL) {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning, !self.movieOutput.isRecording else { return }
            self.recordingStartAnchor = nil
            try? FileManager.default.removeItem(at: url)
            // AVCaptureMovieFileOutput uses movie fragments to keep a partially
            // written QuickTime file playable after a crash. A short interval is
            // worthwhile on the internal disk and limits camera-only loss to the
            // most recent couple of seconds.
            self.movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Mutes/unmutes the microphone for camera-only recordings, where audio is
    /// captured by this session instead of the screen stream. Disables the audio
    /// connection so the camera keeps rolling silently; a no-op when the session
    /// has no audio input (screen + camera mode mutes via the ScreenRecorder).
    func setMicMuted(_ muted: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            for connection in self.movieOutput.connections
            where connection.inputPorts.contains(where: { $0.mediaType == .audio }) {
                connection.isEnabled = !muted
            }
        }
    }

    func stopRecording() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self, self.movieOutput.isRecording else {
                    continuation.resume(); return
                }
                self.stopContinuation = continuation
                self.movieOutput.stopRecording()
            }
        }
    }

    func stopSession() {
        processingQueue.async { [weak self] in self?.attachedProcessedLayer = nil }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let layer = self.attachedPreviewLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.session = nil
                CATransaction.commit()
                self.attachedPreviewLayer = nil
            }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (live background)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard cameraBackground.removesBackground,
              let layer = attachedProcessedLayer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Throttle to ~20fps: skip frames that arrive too soon since the last one.
        let now = CACurrentMediaTime()
        guard now - lastPreviewFrameTime >= previewFrameInterval else { return }
        lastPreviewFrameTime = now
        var image = matte.composite(pixelBuffer, background: cameraBackground)
        if previewMirrored { image = image.oriented(.upMirrored) }
        // Render small — it only feeds a little bubble — to keep this cheap.
        let targetWidth: CGFloat = 640
        if image.extent.width > targetWidth {
            let scale = targetWidth / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = cgImage
            CATransaction.commit()
        }
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        recordingStartAnchor = CACurrentMediaTime()
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
}
