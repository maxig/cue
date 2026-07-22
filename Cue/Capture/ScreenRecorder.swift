import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit
import QuartzCore

/// Captures a display or window with ScreenCaptureKit and writes a single
/// `screen.mov` containing the video plus up to two audio tracks (system audio
/// and microphone) via **one** `AVAssetWriter`.
///
/// Sync is guaranteed by construction: all tracks share one writer session
/// (started at the first video frame's presentation timestamp), and every
/// sample — video, system audio, mic — is appended at its real PTS on the
/// shared ScreenCaptureKit clock. There is no post-hoc re-timing of audio.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    struct Options {
        var filter: SCContentFilter
        var width: Int
        var height: Int
        var fps: Int
        var captureSystemAudio: Bool
        var captureMicrophone: Bool
        var microphoneDeviceID: String?
        var outputFolder: URL
        var showsCursor: Bool = true
    }

    struct Result {
        var screenFileName: String?
        var audioTrackCount: Int
    }

    private let queue = DispatchQueue(label: "com.max.Cue.ScreenRecorder")
    private var stream: SCStream?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var audioTrackCount = 0
    private var didReportWriterError = false

    /// Host-clock time (CACurrentMediaTime) of the first written video frame,
    /// used to align the separately-recorded camera track.
    private(set) var firstFrameAnchor: CFTimeInterval?

    // Pause / mic-mute state — touched only on `queue`.
    private var isPaused = false
    private var pauseAnchorPTS: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var micMuted = false

    // Keep-alive: ScreenCaptureKit only emits a `.complete` frame when the
    // picture actually changes, so a *static* screen (notably while the user is
    // paused, but also any still moment) stops producing samples — the video
    // track then ends earlier than the continuously-flowing audio, and the clip
    // gets truncated. We re-emit the most recent frame on a timer so the video
    // track always keeps pace with audio. All fields touched only on `queue`.
    private var lastVideoBuffer: CVImageBuffer?
    private var lastVideoFormat: CMFormatDescription?
    private var lastVideoPTS: CMTime = .invalid
    private var lastVideoHostTime: CFTimeInterval = 0
    private var frameDuration = CMTime(value: 1, timescale: 30)
    private var keepAliveTimer: DispatchSourceTimer?

    var onStreamError: ((Error) -> Void)?

    // MARK: Start

    func start(options: Options) async throws {
        sessionStarted = false
        audioTrackCount = 0
        firstFrameAnchor = nil
        isPaused = false
        pauseAnchorPTS = nil
        totalPausedDuration = .zero
        micMuted = false
        didReportWriterError = false
        lastVideoBuffer = nil
        lastVideoFormat = nil
        lastVideoPTS = .invalid
        lastVideoHostTime = 0
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        keepAliveTimer?.cancel()
        keepAliveTimer = nil

        let url = options.outputFolder.appendingPathComponent("screen.mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Periodic QuickTime fragments keep all completed fragments playable if
        // Cue or macOS exits before finishWriting can write the final sample table.
        // Flush the first one quickly, then favor efficient ten-second fragments.
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: estimatedBitrate(width: options.width, height: options.height, fps: options.fps),
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.writerSetupFailed }
        writer.add(videoInput)

        if options.captureSystemAudio {
            let input = makeAudioInput()
            if writer.canAdd(input) { writer.add(input); systemAudioInput = input; audioTrackCount += 1 }
        }
        if options.captureMicrophone {
            let input = makeAudioInput()
            if writer.canAdd(input) { writer.add(input); micAudioInput = input; audioTrackCount += 1 }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.writerSetupFailed
        }
        self.writer = writer
        self.videoInput = videoInput

        // Stream configuration
        let config = SCStreamConfiguration()
        config.width = options.width
        config.height = options.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        // Capture just the window itself — no surrounding shadow/transparent
        // margin that would otherwise render as a black border.
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.capturesAudio = options.captureSystemAudio
        config.captureMicrophone = options.captureMicrophone
        if let micID = options.microphoneDeviceID, options.captureMicrophone {
            config.microphoneCaptureDeviceID = micID
        }

        let stream = SCStream(filter: options.filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if options.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            if options.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
            self.stream = stream
            try await stream.startCapture()
            startKeepAlive()
        } catch {
            writer.cancelWriting()
            self.stream = nil
            cleanup()
            throw error
        }
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 160_000
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: Pause / mute

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isPaused = true
            self.pauseAnchorPTS = nil
        }
    }

    func resume() {
        queue.async { [weak self] in self?.isPaused = false }
    }

    func setMicMuted(_ muted: Bool) {
        queue.async { [weak self] in self?.micMuted = muted }
    }

    // MARK: Keep-alive (fill static-screen gaps)

    /// Starts the timer that re-emits the last frame whenever ScreenCaptureKit
    /// goes quiet, so a still screen never truncates the video track. Runs the
    /// handler on `queue`, serialized with the sample handlers.
    private func startKeepAlive() {
        queue.async { [weak self] in
            guard let self else { return }
            self.keepAliveTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.emitKeepAliveFrameIfNeeded() }
            self.keepAliveTimer = timer
            timer.resume()
        }
    }

    /// If real frames have stalled (static screen), re-append the last frame at
    /// the current time so the video track stays as long as the audio. No-op
    /// while frames are flowing normally.
    private func emitKeepAliveFrameIfNeeded() {
        guard sessionStarted, !isPaused, lastVideoPTS.isValid,
              let buffer = lastVideoBuffer, let format = lastVideoFormat,
              let writer, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData else { return }
        let now = CACurrentMediaTime()
        let sinceLast = now - lastVideoHostTime
        guard sinceLast >= 0.1 else { return }   // real frames still arriving
        let span = CMTime(seconds: sinceLast, preferredTimescale: 600)
        let pts = lastVideoPTS + span
        var timing = CMSampleTimingInfo(duration: span, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
        if !input.append(sample) { reportWriterFailure() }
        lastVideoPTS = pts
        lastVideoHostTime = now
    }

    /// Drops samples while paused and, after resume, shifts every sample back by
    /// the total paused duration so the written timeline has no gap. Returns nil
    /// to drop the sample. Runs on `queue` (the sample-handler queue).
    private func gated(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if isPaused {
            if pauseAnchorPTS == nil { pauseAnchorPTS = pts }
            return nil
        }
        if let anchor = pauseAnchorPTS {
            let gap = pts - anchor
            if gap.isValid && gap > .zero { totalPausedDuration = totalPausedDuration + gap }
            pauseAnchorPTS = nil
        }
        if totalPausedDuration == .zero { return sb }
        return Self.retimed(sb, by: totalPausedDuration)
    }

    /// Returns a copy of an audio sample buffer with its PCM payload replaced by
    /// silence, preserving format, timing and sample count. Muting this way keeps
    /// the mic track continuous and frame-aligned — dropping the buffers instead
    /// leaves a hole that the composition collapses, sliding the rest of the mic
    /// audio earlier and drifting out of sync.
    private static func silenced(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sb),
              let srcBlock = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sb)
        let length = CMBlockBufferGetDataLength(srcBlock)
        guard numSamples > 0, length > 0 else { return nil }

        var silentBlock: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &silentBlock)
        guard status == kCMBlockBufferNoErr, let silentBlock else { return nil }
        status = CMBlockBufferFillDataBytes(with: 0, blockBuffer: silentBlock,
                                            offsetIntoDestination: 0, dataLength: length)
        guard status == kCMBlockBufferNoErr else { return nil }

        var timingCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, timingCount))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: &timingCount)

        var sizeCount: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: max(1, sizeCount))
        CMSampleBufferGetSampleSizeArray(sb, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: &sizeCount)

        var out: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: silentBlock,
            formatDescription: formatDesc, sampleCount: numSamples,
            sampleTimingEntryCount: timingCount, sampleTimingArray: &timings,
            sampleSizeEntryCount: sizeCount, sampleSizeArray: &sizes,
            sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    private static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sb,
            sampleTimingEntryCount: count, sampleTimingArray: timings, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    // MARK: Stop

    func stop() async -> Result {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.keepAliveTimer?.cancel()
                self.keepAliveTimer = nil
                self.lastVideoBuffer = nil
                self.lastVideoFormat = nil
                guard let writer = self.writer else { continuation.resume(); return }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micAudioInput?.markAsFinished()
                if writer.status == .writing {
                    writer.finishWriting { continuation.resume() }
                } else {
                    continuation.resume()
                }
            }
        }
        let result = Result(screenFileName: sessionStarted ? "screen.mov" : nil,
                            audioTrackCount: audioTrackCount)
        cleanup()
        return result
    }

    private func cleanup() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micAudioInput = nil
        sessionStarted = false
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let sb = gated(sampleBuffer) else { return }
            handleVideo(sb)
        case .audio:
            guard let sb = gated(sampleBuffer) else { return }
            appendAudio(sb, to: systemAudioInput)
        case .microphone:
            guard let sb = gated(sampleBuffer) else { return }   // pause handling first (shared timing)
            if micMuted {
                // Keep the track continuous with silence instead of dropping, so
                // muting never opens a gap that drifts the audio out of sync.
                // On the rare silencing failure, drop this buffer (don't leak mic).
                guard let quiet = Self.silenced(sb) else { return }
                appendAudio(quiet, to: micAudioInput)
            } else {
                appendAudio(sb, to: micAudioInput)
            }
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isCompleteFrame(sampleBuffer),
              let writer = writer, let input = videoInput else { return }
        if !sessionStarted {
            guard writer.status == .writing else { return }
            // One session start for ALL tracks → shared timeline → locked sync.
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            firstFrameAnchor = CACurrentMediaTime()
            sessionStarted = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        // If keep-alive frames ran slightly ahead of this real frame, nudge it
        // just past them so the track's presentation timestamps stay strictly
        // increasing (AVAssetWriter requires it).
        var toAppend = sampleBuffer
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastVideoPTS.isValid, pts <= lastVideoPTS,
           let bumped = Self.retimed(sampleBuffer, by: pts - (lastVideoPTS + frameDuration)) {
            toAppend = bumped
        }
        if !input.append(toAppend) {
            reportWriterFailure()
            return
        }

        // Remember this frame so the keep-alive timer can re-emit it if the
        // screen goes static and SCK stops delivering frames.
        lastVideoBuffer = CMSampleBufferGetImageBuffer(toAppend)
        lastVideoFormat = CMSampleBufferGetFormatDescription(toAppend)
        lastVideoPTS = CMSampleBufferGetPresentationTimeStamp(toAppend)
        lastVideoHostTime = CACurrentMediaTime()
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        // Drop audio that arrives before the first video frame so the session
        // start (video PTS) is the common zero for every track.
        guard sessionStarted,
              let writer = writer, writer.status == .writing,
              let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) { reportWriterFailure() }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    private func estimatedBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = Double(width * height)
        // Screen content compresses substantially better than camera footage.
        // The old 40 Mbps ceiling made a ten-minute 4K recording approach 3 GB,
        // dominating composition and upload time with little visible improvement.
        let bitrate = pixels * Double(fps) * 0.05
        return Int(min(max(bitrate, 3_000_000), 24_000_000))
    }

    private func reportWriterFailure() {
        guard !didReportWriterError else { return }
        didReportWriterError = true
        onStreamError?(writer?.error ?? RecordingError.compositionFailed("the screen encoder stopped accepting media"))
    }
}

enum RecordingError: LocalizedError {
    case writerSetupFailed
    case noCaptureTarget
    case alreadyRecording
    case cameraSetupFailed
    case compositionFailed(String)

    var errorDescription: String? {
        switch self {
        case .writerSetupFailed: return "Couldn't set up the video writer."
        case .noCaptureTarget: return "No display or window selected to record."
        case .alreadyRecording: return "A recording is already in progress."
        case .cameraSetupFailed: return "Couldn't start the camera."
        case .compositionFailed(let why): return "Couldn't compose the final video: \(why)"
        }
    }
}
