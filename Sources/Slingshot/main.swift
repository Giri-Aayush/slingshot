import AVFoundation
import AppKit
import SlingshotUI
import SlingshotCore
import Vision

// MARK: - Main

log("Slingshot v2.4. Palm then fist to sling a screenshot; snap your fingers for a clipboard copy")

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

var clapMuteEnabled = UserDefaults.standard.bool(forKey: "clapMute")  // opt-in, persisted
/// Serial queue for mute toggles: back-to-back claps must apply in order.
let muteQueue = DispatchQueue(label: "slingshot.mute")

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

// MARK: - Feature switches (shared setters, one stop predicate)

func stopSoundListenerIfUnused() {
    if !snapWakeEnabled && !snapToClipboardEnabled && !clapMuteEnabled {
        snapListener?.stop()
        snapListener = nil
        snapWakeOperational = false
    }
}

func setSnapWake(_ on: Bool) {
    snapWakeEnabled = on
    UserDefaults.standard.set(on, forKey: "snapWake")
    if on {
        log("🫰 Snap-to-wake on. The camera sleeps when idle")
        startSnapListening()
        scheduleWorkDoneSleep()
    } else {
        log("👁️ Camera always on")
        wakeCamera("always-on mode")
        stopSoundListenerIfUnused()
    }
    statusUI?.refresh()
}

func setSnapClipboard(_ on: Bool) {
    snapToClipboardEnabled = on
    UserDefaults.standard.set(on, forKey: "snapToClipboard")
    if on {
        log("🫰 Snap-to-clipboard on")
        startSnapListening()
    } else {
        log("🔇 Snap-to-clipboard off")
        stopSoundListenerIfUnused()
    }
    statusUI?.refresh()
}

func setClapMute(_ on: Bool) {
    if on && !requirePro("Clap to mute") { return }
    clapMuteEnabled = on
    UserDefaults.standard.set(on, forKey: "clapMute")
    if on {
        log("👏 Clap-to-mute on")
        startSnapListening()
    } else {
        log("🔇 Clap-to-mute off. A clap puts the camera to sleep again")
        stopSoundListenerIfUnused()
    }
    statusUI?.refresh()
}

/// Bring up the snap/clap listener if any sound feature is on. Requests
/// microphone access on first use; denial leaves the camera features untouched.
func startSnapListening() {
    guard snapWakeEnabled || snapToClipboardEnabled || clapMuteEnabled, snapListener == nil else { return }

    let begin = {
        // Re-check: the mic prompt takes arbitrarily long, and the user may have
        // toggled features (or another call may have begun a listener) meanwhile.
        guard snapListener == nil, snapWakeEnabled || snapToClipboardEnabled || clapMuteEnabled else { return }
        let listener = SnapListener()
        listener.snapActionEnabled = { snapWakeEnabled || snapToClipboardEnabled }
        // A clap always has a consumer: sleep the camera (default) or toggle mute.
        listener.clapActionEnabled = { true }
        listener.onClap = {
            // Default: the mirror of snap-to-wake, a clap puts the camera to
            // sleep. Opted in, the clap toggles the Mac's output mute instead.
            guard clapMuteEnabled else {
                guard let cam = camera, cam.isRunning else { return }
                log("👏 Clap. Putting the camera to sleep")
                sleepCamera("clap")
                return
            }
            muteQueue.async {
                guard let nowMuted = toggleSystemOutputMute() else {
                    log("❌ Clap heard, but the output device refused the mute toggle")
                    DispatchQueue.main.async {
                        NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Mute failed", kind: .outcome)
                    }
                    return
                }
                log(nowMuted ? "👏 Clap! System sound muted" : "👏 Clap! System sound back on")
                DispatchQueue.main.async {
                    if !nowMuted { play("Pop") }  // a mute confirmation would be inaudible
                    NotchIsland.shared.compact(nowMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                               nowMuted ? NotchIsland.Palette.ash : NotchIsland.Palette.mint,
                                               nowMuted ? "Muted" : "Sound on", kind: .outcome)
                }
            }
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
                var faceLock: (prints: [String], threshold: Float)?
                if currentMode == .normal {
                    // Samples about a second of frames; we are already off the
                    // camera queue, so fresh frames keep arriving underneath.
                    if let enrollment = FaceID.enroll(frames: { frameStore.latest() }) {
                        let encoded = enrollment.prints.compactMap(FaceID.encode)
                        if !encoded.isEmpty { faceLock = (encoded, enrollment.threshold) }
                    }
                    if faceLock == nil {
                        log("⚠️ No face visible at grab time. Sending without a face lock")
                    }
                }
                link.hold(shot, mode: currentMode, faceLock: faceLock)
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
        guard requirePro("Dropping files on the notch") else { return }
        log("🪂 Dropped \(url.lastPathComponent) onto the notch. Holding it")
        DispatchQueue.global(qos: .userInitiated).async {
            link.hold(url, mode: currentMode, faceLock: nil)
        }
    }

    log("🙌 Ready. Snap to wake the camera, palm 2 seconds to arm, fist 1 second to grab.")

    startSnapListening()
}

_ = updaterController  // start Sparkle with the app

enforceFreeTier()

OnboardingWindow.shared.onHandoff = { wakeCamera("welcome done") }
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
