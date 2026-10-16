import AVFoundation
import CoreVideo
import QuartzCore

/// Runs the webcam and keeps the most recent frame for previews and the compositor.
/// Session work happens on `sessionQueue`; frames arrive on `outputQueue`. Nothing here touches the main thread.
final class CameraService: NSObject, @unchecked Sendable {
    typealias FrameSink = (CVPixelBuffer) -> Void

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.utkarsh.Glance.camera.session")
    private let outputQueue = DispatchQueue(label: "dev.utkarsh.Glance.camera.frames", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()

    private let lock = NSLock()
    private var latest: (buffer: CVPixelBuffer, time: CFTimeInterval)?
    private var sinks: [UUID: FrameSink] = [:]

    // sessionQueue only
    private var activeDeviceID: String?
    private var isConfigured = false
    private var observers: [NSObjectProtocol] = []

    /// Called on the main queue when the running camera fails or is unplugged.
    var onProblem: (@MainActor (String) -> Void)?

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            MainActor.assumeIsolated {
                self?.onProblem?(error?.localizedDescription ?? "The camera stopped unexpectedly.")
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Starts (or switches) the camera. Completion runs on the main queue.
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
            lock.lock(); latest = nil; lock.unlock()
        }
    }

    /// Most recent frame, or `nil` if the camera hasn't produced one within `maxAge` seconds
    /// (stopped, unplugged or frozen), in which case the bubble is left out of the recording.
    func latestFrame(maxAge: CFTimeInterval = 1.0) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, CACurrentMediaTime() - latest.time <= maxAge else { return nil }
        return latest.buffer
    }

    func addSink(_ sink: @escaping FrameSink) -> UUID {
        let id = UUID()
        lock.lock(); sinks[id] = sink; lock.unlock()
        return id
    }

    func removeSink(_ id: UUID) {
        lock.lock(); sinks[id] = nil; lock.unlock()
    }

    // MARK: - Configuration (sessionQueue)

    private func configure(deviceID: String?) throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw RecorderError.cameraUnavailable("No camera is connected.") }
        if isConfigured && activeDeviceID == device.uniqueID { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecorderError.cameraUnavailable(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw RecorderError.cameraUnavailable("\(device.localizedName) is in use by another app or unsupported.")
        }
        session.addInput(input)

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(videoOutput) else {
                throw RecorderError.cameraUnavailable("The camera output couldn't be configured.")
            }
            session.addOutput(videoOutput)
        }

        activeDeviceID = device.uniqueID
        isConfigured = true
        lock.lock(); latest = nil; lock.unlock()
        Log.devices.info("Camera configured: \(device.localizedName, privacy: .public)")
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = (pixelBuffer, CACurrentMediaTime())
        let currentSinks = Array(sinks.values)
        lock.unlock()
        currentSinks.forEach { $0(pixelBuffer) }
    }
}
