import AVFoundation
import Vision

/// Front camera + Vision hand pose, built to cost nothing while unused:
/// - The camera runs only between `start()` and `stop()`.
/// - 640×480, the camera's native YUV format (no color conversion), late frames dropped,
///   and Vision is run at most ~15 times per second on one hand.
/// - The session is configured once (camera stays off while it isn't running) so a press only
///   has to power the sensor on; the Vision model is released after 2 minutes without use.
///
/// Callbacks arrive on the main thread.
final class HandGestureCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Failure: Error, Equatable {
        case denied
        case noCamera
        case configuration(String)
    }

    /// The sign seen in the latest frames (nil = none), sent only when it changes.
    var onCandidate: ((HandGesture?) -> Void)?
    /// A sign held steady for `requiredStreak` frames. Sent at most once per `start()`.
    var onConfirmed: ((HandGesture) -> Void)?
    var onFailure: ((Failure) -> Void)?

    static let requiredStreak = 3
    private static let minFrameInterval: TimeInterval = 1.0 / 15.0
    private static let releaseAfter: TimeInterval = 120

    private let sessionQueue = DispatchQueue(label: "com.wai.Isle.camera", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "com.wai.Isle.vision", qos: .userInteractive)
    private let lock = NSLock()
    private var _isActive = false
    private var _generation = 0

    // sessionQueue only
    private var session: AVCaptureSession?
    private var releaseWork: DispatchWorkItem?

    // videoQueue only
    private var request: VNDetectHumanHandPoseRequest?
    private var frameGeneration = -1
    private var startedAt: TimeInterval = 0
    private var loggedFirstFrame = false
    private var lastCandidate: HandGesture?
    private var streak = 0
    private var confirmed = false
    private var lastProcessed: TimeInterval = 0

    private var state: (active: Bool, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_isActive, _generation)
    }

    /// Configures the session ahead of time (no camera power, no light) so the first press is fast.
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.session == nil else { return }
            self.session = try? self.makeSession()
        }
    }

    func start() {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        _isActive = true
        _generation += 1
        let generation = _generation
        lock.unlock()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in self?.startSession(generation: generation, requestedAt: requestedAt) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.sessionQueue.async { self.startSession(generation: generation, requestedAt: requestedAt) }
                } else {
                    self.fail(.denied)
                }
            }
        case .denied, .restricted:
            fail(.denied)
        @unknown default:
            fail(.denied)
        }
    }

    func stop() {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        _isActive = false
        lock.unlock()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let session = self.session, session.isRunning {
                let begin = ProcessInfo.processInfo.systemUptime
                session.stopRunning()
                let end = ProcessInfo.processInfo.systemUptime
                FileLog.write(String(format: "camera: stop waited %.0f ms in queue, stopRunning %.0f ms",
                                     (begin - requestedAt) * 1000, (end - begin) * 1000))
            }
            self.scheduleRelease()
        }
    }

    // MARK: Session (sessionQueue)

    private func startSession(generation: Int, requestedAt: TimeInterval) {
        // Pressed and released before we got here: don't turn the camera on at all.
        let current = state
        guard current.active, current.generation == generation else { return }
        releaseWork?.cancel()
        releaseWork = nil
        if session == nil {
            do {
                session = try makeSession()
            } catch let failure as Failure {
                fail(failure)
                return
            } catch {
                fail(.configuration(error.localizedDescription))
                return
            }
        }
        guard let session, !session.isRunning else { return }
        videoQueue.async { [weak self] in self?.resetTracking(generation: generation, requestedAt: requestedAt) }
        let begin = ProcessInfo.processInfo.systemUptime
        session.startRunning()
        let end = ProcessInfo.processInfo.systemUptime
        FileLog.write(String(format: "camera: start setup %.0f ms, startRunning %.0f ms",
                             (begin - requestedAt) * 1000, (end - begin) * 1000))
        // Released while the camera was starting up.
        if !state.active {
            session.stopRunning()
            scheduleRelease()
        }
    }

    private func makeSession() throws -> AVCaptureSession {
        // The Mac's own camera, never an iPhone Continuity Camera.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            throw Failure.noCamera
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.low) {
            session.sessionPreset = .low
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure.configuration("camera input unavailable") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw Failure.configuration("video output unavailable") }
        session.addOutput(output)
        session.commitConfiguration()

        // Ask the camera itself for 15 fps where the format allows it (less sensor and USB work).
        let fifteen = CMTime(value: 1, timescale: 15)
        let supports15 = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= 15 && $0.maxFrameRate >= 15
        }
        if supports15, (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = fifteen
            device.activeVideoMaxFrameDuration = fifteen
            device.unlockForConfiguration()
        }
        return session
    }

    private func scheduleRelease() {
        releaseWork?.cancel()
        // Only the Vision model is freed; the configured session costs little and keeps the
        // next press fast.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.active else { return }
            self.videoQueue.async { self.request = nil }
        }
        releaseWork = work
        sessionQueue.asyncAfter(deadline: .now() + Self.releaseAfter, execute: work)
    }

    private func fail(_ failure: Failure) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(failure) }
    }

    // MARK: Frames (videoQueue)

    private func resetTracking(generation: Int, requestedAt: TimeInterval) {
        frameGeneration = generation
        startedAt = requestedAt
        loggedFirstFrame = false
        lastCandidate = nil
        streak = 0
        confirmed = false
        lastProcessed = 0
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let current = state
        guard current.active, current.generation == frameGeneration, !confirmed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !loggedFirstFrame {
            loggedFirstFrame = true
            FileLog.write(String(format: "camera: first frame %.0f ms after key press", (now - startedAt) * 1000))
        }
        guard now - lastProcessed >= Self.minFrameInterval * 0.9 else { return }
        lastProcessed = now

        let request = self.request ?? {
            let made = VNDetectHumanHandPoseRequest()
            made.maximumHandCount = 1
            self.request = made
            return made
        }()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return }
        let gesture = request.results?.first.flatMap(Self.gesture(from:))

        if gesture == lastCandidate {
            streak += 1
        } else {
            lastCandidate = gesture
            streak = 1
            DispatchQueue.main.async { [weak self] in self?.onCandidate?(gesture) }
        }
        if let gesture, streak >= Self.requiredStreak {
            confirmed = true
            FileLog.write(String(format: "camera: %@ confirmed %.0f ms after key press", gesture.rawValue, (now - startedAt) * 1000))
            DispatchQueue.main.async { [weak self] in self?.onConfirmed?(gesture) }
        }
    }

    private static func gesture(from observation: VNHumanHandPoseObservation) -> HandGesture? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let recognized = points[joint], recognized.confidence > 0.3 else { return nil }
            return recognized.location
        }
        return HandGesture.classify(
            wrist: point(.wrist),
            tips: [point(.indexTip), point(.middleTip), point(.ringTip), point(.littleTip)],
            pips: [point(.indexPIP), point(.middlePIP), point(.ringPIP), point(.littlePIP)]
        )
    }
}
