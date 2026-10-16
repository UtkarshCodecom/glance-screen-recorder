import AVFoundation
import QuartzCore

/// AVFoundation microphone capture. Drives the input level meter before recording and serves as
/// the fallback recording source if ScreenCaptureKit can't open the selected microphone.
final class MicrophoneService: NSObject, @unchecked Sendable {
    typealias SampleSink = (CMSampleBuffer, _ hostTime: CMTime) -> Void

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.utkarsh.Glance.mic.session")
    private let outputQueue = DispatchQueue(label: "dev.utkarsh.Glance.mic.samples", qos: .userInteractive)
    private let audioOutput = AVCaptureAudioDataOutput()

    private let lock = NSLock()
    private var sampleSink: SampleSink?
    private var lastLevelTime: CFTimeInterval = 0

    // sessionQueue only
    private var activeDeviceID: String?

    /// Normalized input level, delivered on the main queue roughly 20 times a second.
    var onLevel: (@MainActor (Float) -> Void)?

    func start(deviceID: String?, completion: @escaping @MainActor (Error?) -> Void) {
        sessionQueue.async { [self] in
            let result: Error?
            do {
                try configure(deviceID: deviceID)
                if !session.isRunning { session.startRunning() }
                result = nil
            } catch {
                result = error
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    var isRunning: Bool { session.isRunning }

    /// Routes captured buffers (with host-clock timestamps) to a recorder. Pass `nil` to detach.
    func setSampleSink(_ sink: SampleSink?) {
        lock.lock(); sampleSink = sink; lock.unlock()
    }

    private func configure(deviceID: String?) throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? DeviceManager.systemDefaultInputUID().flatMap(AVCaptureDevice.init(uniqueID:))
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecorderError.microphoneUnavailable("No microphone is connected.") }
        if activeDeviceID == device.uniqueID, !session.inputs.isEmpty { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecorderError.microphoneUnavailable(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw RecorderError.microphoneUnavailable("\(device.localizedName) can't be used right now.")
        }
        session.addInput(input)
        if !session.outputs.contains(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(audioOutput) else {
                throw RecorderError.microphoneUnavailable("The microphone output couldn't be configured.")
            }
            session.addOutput(audioOutput)
        }
        activeDeviceID = device.uniqueID
        Log.devices.info("Microphone configured: \(device.localizedName, privacy: .public)")
    }
}

extension MicrophoneService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let sink = sampleSink
        let now = CACurrentMediaTime()
        let shouldMeter = now - lastLevelTime > 0.05
        if shouldMeter { lastLevelTime = now }
        lock.unlock()

        if let sink {
            // Capture timestamps are on the session clock; convert to the host clock shared with ScreenCaptureKit.
            let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
            let hostTime = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
            sink(sampleBuffer, hostTime)
        }
        if shouldMeter, let onLevel, let rms = AudioLevelMeter.rms(of: sampleBuffer) {
            let level = AudioLevelMeter.normalizedLevel(rms: rms)
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
