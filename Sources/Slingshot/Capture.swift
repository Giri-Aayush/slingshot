import AppKit
import AudioToolbox
import AVFoundation
import SlingshotCore
import SoundAnalysis

// MARK: - Screenshot

func takeScreenshot() -> URL? {
    try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd-HHmmss"
    let url = shotsDir.appendingPathComponent("grab-\(df.string(from: Date())).png")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", url.path]
    let errPipe = Pipe()
    p.standardError = errPipe
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        log("❌ screencapture failed to launch: \(error)")
        return nil
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
        log("   · screencapture stderr: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if p.terminationStatus != 0 {
        log("   · screencapture exit code: \(p.terminationStatus)")
    }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// Full-screen grab straight to the clipboard, paste with Cmd-V. Blocking; call off the main thread.
@discardableResult
func copyScreenshotToClipboard() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-c", "-x"]
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        log("❌ screencapture (clipboard) failed to launch: \(error)")
        return false
    }
    return p.terminationStatus == 0
}

// MARK: - Finger-snap and clap listener

/// Fires onSnap when Apple's on-device sound classifier hears a finger snap,
/// onClap when it hears a clap. All analysis is local; no audio leaves the Mac.
/// One shared debounce covers both: a snap and a clap are near-identical
/// transients, so routeSoundWindow picks a single winner per window.
final class SnapListener: NSObject, SNResultsObserving {
    var onSnap: () -> Void = {}
    var onClap: () -> Void = {}
    /// Whether each action currently has a consumer; see routeSoundWindow.
    var snapActionEnabled: () -> Bool = { true }
    var clapActionEnabled: () -> Bool = { true }
    var debounce: TimeInterval = 1.2
    var debugLogging = true

    private let audio = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let queue = DispatchQueue(label: "slingshot.snap")
    private var lastFire = Date.distantPast
    private var tapBeats = 0

    func start() throws {
        guard !audio.isRunning else { return }
        let input = audio.inputNode

        // Pin the built-in mic ONLY when something else holds the default-input
        // role (a Bluetooth speaker's far-field mic hears no claps). When the
        // default already is the built-in mic, leave the engine untouched;
        // pinning under AVAudioEngine can leave its render chain silent.
        var pinned = false
        if let builtIn = builtInInputDeviceID(), defaultInputDeviceID() != builtIn,
           let unit = input.audioUnit {
            var device = builtIn
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &device,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            var applied = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &applied, &size)
            pinned = err == noErr && applied == builtIn
            if pinned {
                log("🎙️ Pinned the built-in microphone (default input was elsewhere)")
            } else {
                log("⚠️ Could not pin the built-in microphone (err \(err)). Using the system input")
            }
        }

        // Unpinned, the tap sees the node's client-side format, the stock path.
        // Pinned, the node's cached client format can describe the OLD device
        // (an uncatchable installTap exception), so use the hardware format.
        let format = pinned ? input.inputFormat(forBus: 0) : input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RuntimeError("Microphone input unavailable")
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard request.knownClassifications.contains("finger_snapping") else {
            throw RuntimeError("Sound classifier has no finger_snapping class")
        }
        if !request.knownClassifications.contains("clapping") {
            // Snaps still work; claps just will not fire on this classifier.
            log("⚠️ Sound classifier has no clapping class. Clap features unavailable")
        }
        // High overlap trades a little CPU for catching a snap anywhere in the window.
        request.overlapFactor = 0.75
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer

        input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, when in
            self?.queue.async {
                guard let self else { return }
                // Heartbeat: proves audio is actually flowing, with rough level.
                self.tapBeats += 1
                if self.debugLogging, self.tapBeats % 30 == 1 {
                    var level: Float = 0
                    if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                        var sum: Float = 0
                        let n = Int(buffer.frameLength)
                        for i in stride(from: 0, to: n, by: 16) { sum += abs(data[i]) }
                        level = sum / Float((n + 15) / 16)
                    }
                    log(String(format: "   · mic heartbeat #%d level %.4f", self.tapBeats, level))
                }
                self.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
            }
        }
        audio.prepare()
        try audio.start()
        let clapAction = clapMuteEnabled ? "mutes or unmutes the Mac" : "puts the camera to sleep"
        log("🫰 Listening for finger snaps and claps. A clap \(clapAction)")
    }

    func stop() {
        guard audio.isRunning else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        analyzer?.removeAllRequests()
        analyzer = nil
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let snapConfidence = result.classification(forIdentifier: "finger_snapping")?.confidence ?? 0
        // Room acoustics smear a single clap across "clapping" and "applause".
        let clapConfidence = max(result.classification(forIdentifier: "clapping")?.confidence ?? 0,
                                 result.classification(forIdentifier: "applause")?.confidence ?? 0)
        guard let trigger = routeSoundWindow(snapConfidence: snapConfidence,
                                             clapConfidence: clapConfidence,
                                             snapEnabled: snapActionEnabled(),
                                             clapEnabled: clapActionEnabled()) else { return }
        let now = Date()
        // One debounce for both sounds, so a snap's tail can never read as a clap.
        guard now.timeIntervalSince(lastFire) >= debounce else { return }
        lastFire = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch trigger {
            case .snap: self.onSnap()
            case .clap: self.onClap()
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        log("❌ Snap listener failed: \(error.localizedDescription)")
    }
}

// MARK: - Camera

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "slingshot.camera")
    private let onFrame: (CVPixelBuffer) -> Void
    private var frameCount = 0

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    private var configured = false
    private var deviceName = "camera"

    var isRunning: Bool { session.isRunning }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    func start() throws {
        if configured {
            guard !session.isRunning else { return }
            session.startRunning()
            log("🎥 Camera awake (\(deviceName))")
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw RuntimeError("No camera found")
        }
        deviceName = device.localizedName
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RuntimeError("Cannot use camera input") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RuntimeError("Cannot attach video output") }
        session.addOutput(output)

        configured = true
        session.startRunning()
        log("🎥 Camera running (\(device.localizedName))")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount % 2 == 0, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pb)
    }
}

