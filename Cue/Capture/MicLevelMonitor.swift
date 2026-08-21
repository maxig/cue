import AVFoundation
import Accelerate
import Combine

/// Live input level for the selected microphone, shown in the popover while it
/// is open.
///
/// Exists because a dead microphone is otherwise invisible until after a
/// recording: the picker happily lists a device, capture happily writes a track,
/// and only afterwards does it turn out the track holds nothing but room tone.
/// A meter that doesn't move is immediate, honest feedback.
///
/// Threading: the published state below belongs to the main actor, the capture
/// session belongs to `MicSession` and its own queue, and nothing straddles the
/// two — see `MicSession` for why that matters.
@MainActor
final class MicLevelMonitor: NSObject, ObservableObject {

    /// Current level, 0…1, already smoothed for display.
    @Published private(set) var level: Double = 0
    /// Loudest level seen since monitoring started, so brief speech still
    /// registers even if the user looks a moment later.
    @Published private(set) var peak: Double = 0
    /// Whether the meter is actually live. Published rather than read back off
    /// the session, which is only safe to touch on its own queue.
    @Published private(set) var isRunning = false
    /// Loudest level heard since monitoring started, in dB, or nil before any
    /// audio has arrived. Kept alongside the 0…1 bar because the advice worth
    /// giving depends on the real level, not on the drawn one.
    @Published private(set) var loudestDecibels: Double?
    /// The selected device's input volume, 0…1, when it has an adjustable one.
    @Published private(set) var inputGain: Double?

    /// Quietest level the bar shows at all, and the level that fills it. Speech
    /// into a well-set-up microphone sits near -25 dB; the floor goes low enough
    /// that a badly attenuated one still visibly moves instead of reading as a
    /// flat, dead line — which is the one thing this meter must never do.
    private static let floorDecibels = -60.0
    private static let ceilingDecibels = -10.0
    /// Below this, the loudest thing said still transcribes to nothing:
    /// captions count a peak under -26 dBFS as silence, and windowed RMS runs
    /// roughly 12 dB below peak.
    private static let tooQuietDecibels = -38.0

    private let session = MicSession()
    /// The device the meter is meant to be showing. Lets a start result that
    /// lands after the selection moved on be ignored rather than believed.
    private var requestedDeviceID: String?

    /// Whether anything at all has been heard — a flat zero here is the symptom
    /// worth surfacing.
    var hasHeardAnything: Bool { peak > 0.01 }

    /// Something is being heard, but so faintly that a recording of it would
    /// come back from the transcriber empty. Worth telling apart from a dead
    /// microphone: the fix is a volume slider, not a different device.
    var isTooQuiet: Bool {
        guard isRunning, let loudest = loudestDecibels else { return false }
        return loudest < Self.tooQuietDecibels
    }

    /// Starts (or re-points) monitoring. Idempotent for the same device.
    func start(deviceID: String?) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        guard let deviceID else { stop(); return }
        // Only a real change of device clears what we've heard: re-pointing at
        // the same one happens on every selection change and must not wipe it.
        if requestedDeviceID != deviceID {
            requestedDeviceID = deviceID
            level = 0
            peak = 0
            loudestDecibels = nil
        }
        // Re-read each time the popover opens or the choice changes, so turning
        // the slider up and coming back clears the warning.
        inputGain = AudioInputGain.forDevice(uniqueID: deviceID)
        session.start(deviceID: deviceID, delegate: self) { [weak self] running in
            guard let self, self.requestedDeviceID == deviceID else { return }
            self.isRunning = running
        }
    }

    func stop() {
        requestedDeviceID = nil
        isRunning = false
        level = 0
        peak = 0
        loudestDecibels = nil
        inputGain = nil
        session.stop()
    }
}

extension MicLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let rms = Self.rms(of: sampleBuffer) else { return }
        // Speech lives roughly between -50 dB and -10 dB; map that onto the bar
        // so ordinary talking fills most of it rather than a sliver.
        let db = Double(20 * log10(max(rms, 1e-7)))
        let span = Self.ceilingDecibels - Self.floorDecibels
        let normalized = min(max((db - Self.floorDecibels) / span, 0), 1)
        Task { @MainActor [weak self] in
            // A buffer still in flight when the meter stopped must not light it
            // back up — the popover is gone and capture is taking the device.
            guard let self, self.requestedDeviceID != nil else { return }
            // Rise fast so a syllable shows, fall slowly so it stays readable.
            self.level = normalized > self.level ? normalized : self.level * 0.82 + normalized * 0.18
            self.peak = max(self.peak, normalized)
            self.loudestDecibels = max(self.loudestDecibels ?? -.infinity, db)
        }
    }

    private nonisolated static func rms(of sampleBuffer: CMSampleBuffer) -> Float? {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let data = list.mBuffers.mData else { return nil }

        let count = Int(list.mBuffers.mDataByteSize) / (Int(asbd.mBitsPerChannel) / 8)
        guard count > 0 else { return nil }
        var value: Float = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            vDSP_rmsqv(data.assumingMemoryBound(to: Float.self), 1, &value, vDSP_Length(count))
        } else if asbd.mBitsPerChannel == 16 {
            let samples = data.assumingMemoryBound(to: Int16.self)
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(samples, 1, &floats, 1, vDSP_Length(count))
            var scale = Float(Int16.max)
            vDSP_vsdiv(floats, 1, &scale, &floats, 1, vDSP_Length(count))
            vDSP_rmsqv(floats, 1, &value, vDSP_Length(count))
        } else {
            return nil
        }
        return value.isFinite ? value : nil
    }
}

/// Owns the capture session behind the meter.
///
/// Every touch of the session — configuration and start/stop alike — happens on
/// `sessionQueue`, in order, and sample buffers arrive on a separate queue. This
/// is the same arrangement `CameraEngine` uses, and it is not optional: 1.6.2
/// dispatched `stopRunning()` onto a background queue and then immediately ran
/// `beginConfiguration()`/`commitConfiguration()` on the main thread, so the
/// stop regularly landed inside the configuration window. AVFoundation throws
/// on that, and an uncaught Objective-C exception aborts the process — Cue died
/// on both paths that stop the meter: starting a recording, and opening the
/// area picker (which closes the popover).
private final class MicSession: @unchecked Sendable {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.max.Cue.MicLevel")
    /// Separate from `sessionQueue` so stopping the session never waits on the
    /// queue that is delivering its buffers.
    private let sampleQueue = DispatchQueue(label: "com.max.Cue.MicLevelSamples")
    // Both touched only on `sessionQueue`.
    private var input: AVCaptureDeviceInput?
    private var currentDeviceID: String?

    func start(deviceID: String,
               delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
               running: @escaping @MainActor (Bool) -> Void) {
        sessionQueue.async { [self] in
            if session.isRunning, currentDeviceID == deviceID {
                report(true, to: running)
                return
            }
            teardown()

            guard let device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio),
                  let deviceInput = try? AVCaptureDeviceInput(device: device) else {
                report(false, to: running)
                return
            }

            session.beginConfiguration()
            if session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
                input = deviceInput
            }
            output.setSampleBufferDelegate(delegate, queue: sampleQueue)
            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()

            // No input means no meter; say so rather than showing a dead bar
            // that looks exactly like a microphone hearing nothing.
            guard input != nil else { report(false, to: running); return }
            currentDeviceID = deviceID
            session.startRunning()
            report(session.isRunning, to: running)
        }
    }

    /// Releases the device. Asynchronous, like `start`: the recording path calls
    /// this and then runs a countdown before capture claims the microphone, so
    /// there is time in hand — whereas blocking the main thread on a session
    /// that may be mid-start would stall the UI on every Start Recording.
    func stop() {
        sessionQueue.async { [self] in teardown() }
    }

    /// `sessionQueue` only. Stops first, then reconfigures — never the two
    /// interleaved, which is the crash this file exists to avoid.
    private func teardown() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.outputs.contains(output) { session.removeOutput(output) }
        session.commitConfiguration()
        output.setSampleBufferDelegate(nil, queue: nil)
        input = nil
        currentDeviceID = nil
    }

    private func report(_ running: Bool, to callback: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in callback(running) }
    }
}
