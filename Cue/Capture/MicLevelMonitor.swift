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
@MainActor
final class MicLevelMonitor: NSObject, ObservableObject {

    /// Current level, 0…1, already smoothed for display.
    @Published private(set) var level: Double = 0
    /// Loudest level seen since monitoring started, so brief speech still
    /// registers even if the user looks a moment later.
    @Published private(set) var peak: Double = 0

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.max.Cue.MicLevel")
    private var input: AVCaptureDeviceInput?
    private var currentDeviceID: String?

    var isRunning: Bool { session.isRunning }
    /// Whether anything at all has been heard — a flat zero here is the symptom
    /// worth surfacing.
    var hasHeardAnything: Bool { peak > 0.01 }

    /// Starts (or re-points) monitoring. Idempotent for the same device.
    func start(deviceID: String?) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        guard let deviceID else { stop(); return }
        if session.isRunning, currentDeviceID == deviceID { return }

        stop()
        guard let device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input); self.input = input }
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        currentDeviceID = deviceID
        peak = 0
        let session = self.session
        queue.async { session.startRunning() }
    }

    func stop() {
        let session = self.session
        if session.isRunning { queue.async { session.stopRunning() } }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.outputs.contains(output) { session.removeOutput(output) }
        session.commitConfiguration()
        input = nil
        currentDeviceID = nil
        level = 0
        peak = 0
    }
}

extension MicLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let rms = Self.rms(of: sampleBuffer) else { return }
        // Speech lives roughly between -50 dB and -10 dB; map that onto the bar
        // so ordinary talking fills most of it rather than a sliver.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = min(max((Double(db) + 50) / 40, 0), 1)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Rise fast so a syllable shows, fall slowly so it stays readable.
            self.level = normalized > self.level ? normalized : self.level * 0.82 + normalized * 0.18
            self.peak = max(self.peak, normalized)
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
