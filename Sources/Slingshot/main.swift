import AVFoundation
import AppKit
import SlingshotCore
import Vision

// MARK: - Main

log("Slingshot v2.2. Palm then fist to sling a screenshot; snap your fingers for a clipboard copy")

// A real NSApplication event loop so Finder/LaunchServices see the app check in.
// Without this, a double-clicked launch gets flagged "not responding".
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let link = PeerLink()
let engine = GestureEngine()
let handRequest = VNDetectHumanHandPoseRequest()
handRequest.maximumHandCount = 1
var camera: Camera?
var statusUI: StatusUI?
var snapListener: SnapListener?
var snapToClipboardEnabled = UserDefaults.standard.bool(forKey: "snapToClipboard")  // opt-in, persisted
/// True only while the snap listener is actually running. When the pipeline is
/// unavailable (mic denied, audio engine failure) the camera must not doze,
/// because nothing could wake it.
var snapWakeOperational = false

var snapWakeEnabled: Bool = {
    // Default on: the camera sleeps until a snap wakes it.
    UserDefaults.standard.object(forKey: "snapWake") == nil || UserDefaults.standard.bool(forKey: "snapWake")
}()

let cameraControlQueue = DispatchQueue(label: "slingshot.camera.control")

func wakeCamera(_ reason: String) {
    guard let cam = camera, !cam.isRunning else { return }
    // startRunning blocks; Apple requires it off the main thread.
    cameraControlQueue.async {
        do {
            try cam.start()
            frameStore.markHand()
            log("👁️ Camera awake (\(reason))")
            DispatchQueue.main.async {
                play("Tink")
                NotchIsland.shared.compact("eye.fill", NotchIsland.Palette.ice, "")
                statusUI?.refresh()
            }
        } catch {
            log("❌ Camera failed to wake: \(error)")
        }
    }
}

func sleepCamera(_ reason: String) {
    guard snapWakeEnabled, snapWakeOperational, let cam = camera, cam.isRunning else { return }
    guard !link.isHolding, !link.hasRemoteHold, !link.hasActiveTransfers else { return }
    cameraControlQueue.async { cam.stop() }
    frameStore.clear()
    log("😴 Camera asleep (\(reason)). Snap to wake")
    DispatchQueue.main.async { statusUI?.refresh() }
}

/// Called when a transfer finishes: doze off unless a hand is still around.
func scheduleWorkDoneSleep() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        if Date().timeIntervalSince(frameStore.lastHand()) > 3 {
            sleepCamera("work done")
        }
    }
}

/// Bring up the snap listener if the user turned it on. Requests microphone access
/// on first use; denial leaves the camera features untouched.
func startSnapListening() {
    guard snapWakeEnabled || snapToClipboardEnabled, snapListener == nil else { return }

    let begin = {
        let listener = SnapListener()
        listener.onClap = {
            guard let cam = camera, cam.isRunning else { return }
            log("👏 Clap. Putting the camera to sleep")
            sleepCamera("clap")
        }
        listener.onSnap = {
            if snapWakeEnabled, let cam = camera, !cam.isRunning {
                wakeCamera("snap")
                return
            }
            guard snapToClipboardEnabled else { return }
            log("🫰 Snap! Copying a screenshot to the clipboard…")
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = copyScreenshotToClipboard()
                DispatchQueue.main.async {
                    if ok {
                        play("Pop")
                        flashScreen()
                        NotchIsland.shared.compact("doc.on.clipboard.fill", NotchIsland.Palette.mint, "Copied", kind: .outcome)
                    } else {
                        NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Failed", kind: .outcome)
                    }
                }
            }
        }
        do {
            try listener.start()
            snapListener = listener
            snapWakeOperational = true
        } catch {
            log("❌ Snap listener did not start: \(error)")
            snapWakeOperational = false
            if snapWakeEnabled { wakeCamera("snap unavailable, always-on fallback") }
        }
    }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        begin()
    case .notDetermined:
        log("… Waiting for microphone approval (snap features)")
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if ok {
                    begin()
                } else {
                    log("🎤 Microphone denied. Snap features stay off")
                    NotchIsland.shared.compact("mic.slash.fill", NotchIsland.Palette.ash, "Mic off", kind: .outcome)
                    if snapWakeEnabled { wakeCamera("microphone denied, always-on fallback") }
                }
            }
        }
    default:
        log("🎤 Microphone denied. Enable Slingshot in System Settings, Privacy and Security, Microphone")
        if snapWakeEnabled { wakeCamera("microphone denied, always-on fallback") }
    }
}

func startEverything() {
    statusUI = StatusUI()

    // Screen-recording permission: without it screencapture returns nothing useful.
    if !CGPreflightScreenCaptureAccess() {
        log("⚠️ Screen Recording permission missing. Requesting now. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Slingshot.")
        NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.amber, "No screen access", kind: .outcome, seconds: 5)
        CGRequestScreenCaptureAccess()
    }

    link.start()

    // A Mac never grabs while it is holding, has a catch pending, or just caught.
    // Otherwise the catcher's own hand re-triggers a grab on the receiving Mac.
    engine.grabAllowed = {
        !link.isHolding && !link.hasRemoteHold && !link.grabMuted
    }

    engine.releaseAllowed = {
        link.hasRemoteHold
    }

    engine.onGrabSuppressed = {
        log("⏸️ Grab paused while a hold is pending")
        DispatchQueue.main.async {
            NotchIsland.shared.compact("pause.circle.fill", NotchIsland.Palette.ash, "Paused")
        }
    }

    engine.onRelease = {
        link.catchGesture()
    }

    engine.onReleasePrimed = {
        play("Tink")
        log("👊 Fist seen. Open your hand to drop it here")
        DispatchQueue.main.async {
            NotchIsland.shared.compact("arrow.down.circle.fill", NotchIsland.Palette.amber, "Open hand", kind: .prompt, pulsing: true)
        }
    }

    engine.feedback = { log($0) }

    engine.onArmed = {
        play("Tink")
        DispatchQueue.main.async {
            NotchIsland.shared.compact("hand.raised.fill", NotchIsland.Palette.amber, "Armed")
        }
    }

    engine.onGrab = {
        play("Pop")
        // Off the camera queue: screencapture blocks for hundreds of milliseconds.
        DispatchQueue.global(qos: .userInitiated).async {
            log("✊ GRAB! Taking screenshot…")
            if let shot = takeScreenshot() {
                log("🖼  Screenshot saved: \(shot.lastPathComponent)")
                if let img = NSImage(contentsOf: shot) {
                    DispatchQueue.main.async {
                        flashScreen()
                        animateGrab(image: img)
                    }
                }
                var ownerFace: String?
                if currentMode == .normal {
                    if let frame = frameStore.latest(), let fp = FaceID.faceprint(from: frame),
                       let encoded = FaceID.encode(fp) {
                        ownerFace = encoded
                        log("🙂 Face captured. This grab is locked to you")
                    } else {
                        log("⚠️ No face visible at grab time. Sending without a face lock")
                    }
                }
                link.hold(shot, mode: currentMode, ownerFace: ownerFace)
            } else {
                log("❌ Screenshot failed. Check Screen Recording permission")
                DispatchQueue.main.async {
                    NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Failed", kind: .outcome)
                }
            }
        }
    }

    let cam = Camera { pixelBuffer in
        frameStore.set(pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([handRequest])) != nil else { return }
        if let obs = handRequest.results?.first {
            frameStore.markHand()
            let (pose, wrist, debug) = classify(obs)
            engine.update(pose: pose, wrist: wrist, debug: debug)
        } else {
            engine.update(pose: .unknown, wrist: nil, debug: "no hand")
        }
    }
    camera = cam

    if snapWakeEnabled {
        log("😴 Camera starts asleep. Snap your fingers to wake it")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotchIsland.shared.compact("moon.zzz.fill", NotchIsland.Palette.amber, "Snap to wake", kind: .prompt, pulsing: true, seconds: 4)
        }
    } else {
        wakeCamera("always-on mode")
    }

    // Doze off after 15 seconds without a hand in view and nothing pending.
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
        guard snapWakeEnabled, snapWakeOperational, let cam = camera, cam.isRunning else { return }
        if Date().timeIntervalSince(frameStore.lastHand()) > 15 {
            sleepCamera("idle")
        }
    }

    NotchIsland.shared.statusProvider = {
        let peers = link.session.connectedPeers
        let title = peers.isEmpty ? "No Macs connected" : "\(peers.count) Mac\(peers.count == 1 ? "" : "s") connected"
        let cam = (camera?.isRunning ?? false) ? "Camera awake" : "Camera asleep, snap to wake"
        let mode = currentMode == .normal ? "Normal mode" : "Pro mode"
        return (title, "\(cam) · \(mode)")
    }

    NotchIsland.shared.onDropFile = { url in
        log("🪂 Dropped \(url.lastPathComponent) onto the notch. Holding it")
        DispatchQueue.global(qos: .userInitiated).async {
            link.hold(url, mode: currentMode, ownerFace: nil)
        }
    }

    log("🙌 Ready. Snap to wake the camera, palm 2 seconds to arm, fist 1 second to grab.")

    startSnapListening()
}

_ = updaterController  // start Sparkle with the app

OnboardingWindow.shared.showIfNeeded {
    log("🎓 Onboarding done")
}

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    DispatchQueue.main.async { startEverything() }
case .notDetermined:
    log("… Waiting for you to approve camera access")
    AVCaptureDevice.requestAccess(for: .video) { ok in
        DispatchQueue.main.async {
            if ok {
                startEverything()
            } else {
                log("❌ Camera access denied. Enable Slingshot in System Settings → Privacy & Security → Camera, then reopen.")
                app.terminate(nil)
            }
        }
    }
default:
    log("❌ Camera access denied. Enable Slingshot in System Settings → Privacy & Security → Camera, then reopen.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.terminate(nil) }
}

app.run()
