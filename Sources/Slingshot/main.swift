import AVFoundation
import AppKit
import MultipeerConnectivity
import Vision

// MARK: - Helpers

let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Slingshot.log")
let shotsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Slingshot", isDirectory: true)

func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    fflush(stdout)
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

func play(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}

func cleanName(_ s: String) -> String {
    s.components(separatedBy: "#").first ?? s
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Visual effects (all must be called on the main thread)

func flashScreen() {
    guard let screen = NSScreen.main else { return }
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .screenSaver
    w.backgroundColor = .white
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false
    w.alphaValue = 0.8
    w.orderFront(nil)
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.35
        w.animator().alphaValue = 0
    }, completionHandler: { w.orderOut(nil) })
}

private func makeImageWindow(image: NSImage, frame: NSRect) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = .screenSaver
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false
    w.hasShadow = true
    let iv = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
    iv.image = image
    iv.imageScaling = .scaleAxesIndependently
    iv.autoresizingMask = [.width, .height]
    iv.wantsLayer = true
    iv.layer?.cornerRadius = 14
    iv.layer?.masksToBounds = true
    iv.layer?.borderWidth = 2
    iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
    w.contentView = iv
    return w
}

/// The screenshot appears large, then shrinks toward the bottom-right corner — "grabbed" off the screen.
func animateGrab(image: NSImage) {
    guard let screen = NSScreen.main else { return }
    let sf = screen.visibleFrame
    let aspect = image.size.height / max(image.size.width, 1)
    let startW = sf.width * 0.5
    let start = NSRect(x: sf.midX - startW / 2, y: sf.midY - startW * aspect / 2,
                       width: startW, height: startW * aspect)
    let end = NSRect(x: sf.maxX - 150, y: sf.minY + 40, width: 110, height: 110 * aspect)

    let w = makeImageWindow(image: image, frame: start)
    w.orderFront(nil)
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.6
        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        w.animator().setFrame(end, display: true)
        w.animator().alphaValue = 0.05
    }, completionHandler: { w.orderOut(nil) })
}

/// A received screenshot zooms up into the center of the screen, holds, then fades and hands off.
func animateReceive(image: NSImage, then completion: @escaping () -> Void) {
    guard let screen = NSScreen.main else { completion(); return }
    let sf = screen.visibleFrame
    let aspect = image.size.height / max(image.size.width, 1)
    let endW = sf.width * 0.55
    let end = NSRect(x: sf.midX - endW / 2, y: sf.midY - endW * aspect / 2,
                     width: endW, height: endW * aspect)
    let start = NSRect(x: sf.midX - 50, y: sf.midY - 50 * aspect, width: 100, height: 100 * aspect)

    let w = makeImageWindow(image: image, frame: start)
    w.alphaValue = 0.2
    w.orderFront(nil)
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.45
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        w.animator().setFrame(end, display: true)
        w.animator().alphaValue = 1.0
    }, completionHandler: {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
                completion()
            })
        }
    })
}

/// Small translucent banner at the top of the screen.
func showToast(_ text: String) {
    guard let screen = NSScreen.main else { return }
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 16, weight: .semibold)
    label.textColor = .white
    label.sizeToFit()
    let padX: CGFloat = 20
    let padY: CGFloat = 10
    let size = NSSize(width: label.frame.width + padX * 2, height: label.frame.height + padY * 2)
    let rect = NSRect(x: screen.frame.midX - size.width / 2,
                      y: screen.visibleFrame.maxY - size.height - 24,
                      width: size.width, height: size.height)

    let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = .screenSaver
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false

    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
    container.layer?.cornerRadius = size.height / 2
    label.setFrameOrigin(NSPoint(x: padX, y: padY))
    container.addSubview(label)
    w.contentView = container
    w.orderFront(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }
}

// MARK: - Hand pose classification

enum HandPose { case open, fist, unknown }

func classify(_ obs: VNHumanHandPoseObservation) -> (pose: HandPose, debug: String) {
    func point(_ j: VNHumanHandPoseObservation.JointName) -> CGPoint? {
        guard let p = try? obs.recognizedPoint(j), p.confidence > 0.2 else { return nil }
        return p.location
    }
    guard let wrist = point(.wrist), let mcp = point(.middleMCP) else { return (.unknown, "no wrist/palm") }
    let handSize = hypot(wrist.x - mcp.x, wrist.y - mcp.y)
    guard handSize > 0.02 else { return (.unknown, "hand too small") }

    let tips: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
    var extended = 0
    var curled = 0
    var reaches: [String] = []
    for tip in tips {
        if let p = point(tip) {
            let reach = hypot(p.x - wrist.x, p.y - wrist.y) / handSize
            reaches.append(String(format: "%.2f", reach))
            if reach > 1.45 { extended += 1 } else if reach < 1.35 { curled += 1 }
        } else {
            // A fingertip Vision can't see on a detected hand is usually curled into the palm.
            curled += 1
            reaches.append("hidden")
        }
    }
    let debug = "ext=\(extended) curl=\(curled) reach=[\(reaches.joined(separator: " "))]"
    if extended == 4 { return (.open, debug) }
    if extended == 0 && curled >= 2 { return (.fist, debug) }
    return (.unknown, debug)
}

// MARK: - Gesture state machine

final class GestureEngine {
    var onGrab: () -> Void = {}
    var debugLogging = true

    private var openFrames = 0
    private var fistFrames = 0
    private var armedAt: Date?
    private var cooldownUntil = Date.distantPast
    private var announcedReady = true
    private var lastPose: HandPose = .unknown

    // Effective frame rate is ~15 fps (every 2nd camera frame).
    private let framesToArm = 6      // ~0.4 s of steady open palm
    private let framesToGrab = 2     // ~0.13 s of fist
    private let armTimeout: TimeInterval = 3.0
    private let cooldown: TimeInterval = 2.0

    func update(pose: HandPose, debug: String = "") {
        let now = Date()
        if debugLogging, pose != lastPose {
            log("   · pose → \(pose) (\(debug))")
        }
        lastPose = pose

        guard now >= cooldownUntil else { return }
        if !announcedReady {
            announcedReady = true
            log("🔄 Ready — show your palm to grab again")
        }

        if let armed = armedAt {
            if now.timeIntervalSince(armed) > armTimeout {
                log("⌛️ Gesture timed out — show your palm again to re-arm")
                reset()
                return
            }
            switch pose {
            case .fist:
                fistFrames += 1
                if fistFrames >= framesToGrab {
                    reset()
                    cooldownUntil = now.addingTimeInterval(cooldown)
                    announcedReady = false
                    onGrab()
                }
            case .open:
                armedAt = now  // palm still showing: stay armed
                fistFrames = 0
            case .unknown:
                break          // hand mid-transition; keep waiting
            }
        } else {
            if pose == .open {
                openFrames += 1
                if openFrames >= framesToArm {
                    armedAt = Date()
                    play("Tink")
                    log("✋ Palm detected — close your fist to grab the screen")
                }
            } else {
                openFrames = 0
            }
        }
    }

    private func reset() {
        openFrames = 0
        fistFrames = 0
        armedAt = nil
    }
}

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

// MARK: - Peer-to-peer link

final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "slingshot"

    let peerID: MCPeerID
    let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var discovered: Set<MCPeerID> = []
    private var retryTimer: Timer?

    override init() {
        let host = Host.current().localizedName ?? "Mac"
        // Random suffix so two identically named MacBooks never collide.
        peerID = MCPeerID(displayName: "\(host)#\(Int.random(in: 100...999))")
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        log("📡 Looking for peers on the local network as \"\(peerID.displayName)\"…")
        retryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.retryInvites()
        }
    }

    private func shouldInvite(_ id: MCPeerID) -> Bool {
        // Only the lexicographically smaller name invites, so the two sides don't double-connect.
        peerID.displayName < id.displayName
    }

    private func retryInvites() {
        for id in discovered where !session.connectedPeers.contains(id) && shouldInvite(id) {
            log("🔁 Retrying connection to \(id.displayName)…")
            browser.invitePeer(id, to: session, withContext: nil, timeout: 15)
        }
    }

    func send(_ url: URL) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            log("📦 No peer connected — screenshot kept locally at \(url.path)")
            DispatchQueue.main.async { showToast("📦 No Mac connected — saved to Pictures/Slingshot") }
            return
        }
        let sender = (Host.current().localizedName ?? "Mac")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let name = "from-\(sender)-\(url.lastPathComponent)"
        for peer in peers {
            log("🚀 Beaming \(name) to \(peer.displayName)…")
            session.sendResource(at: url, withName: name, toPeer: peer) { error in
                if let error {
                    log("❌ Send to \(peer.displayName) failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { showToast("❌ Send failed: \(error.localizedDescription)") }
                } else {
                    log("✅ Delivered to \(peer.displayName)")
                    DispatchQueue.main.async {
                        showToast("✅ Sent to \(cleanName(peer.displayName))")
                        play("Purr")
                    }
                }
            }
        }
    }

    // MARK: Browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer id: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        log("🔍 Found peer \(id.displayName)")
        discovered.insert(id)
        if shouldInvite(id) {
            browser.invitePeer(id, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
        log("👋 Lost sight of \(id.displayName)")
        discovered.remove(id)
    }

    // MARK: Advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer id: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        log("📨 Invitation from \(id.displayName) — accepting")
        invitationHandler(true, session)
    }

    // MARK: Session

    func session(_ session: MCSession, peer id: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connecting:
            log("…  Connecting to \(id.displayName)")
        case .connected:
            log("🤝 Connected to \(id.displayName) — ready to beam")
            DispatchQueue.main.async {
                play("Hero")
                showToast("🤝 Connected to \(cleanName(id.displayName))")
                statusUI?.refresh()
            }
        case .notConnected:
            log("🔌 Disconnected from \(id.displayName)")
            DispatchQueue.main.async { statusUI?.refresh() }
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer id: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName name: String,
                 fromPeer id: MCPeerID, with progress: Progress) {
        log("📥 Receiving \(name) from \(id.displayName)…")
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String,
                 fromPeer id: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let error {
            log("❌ Receive failed: \(error.localizedDescription)")
            return
        }
        guard let localURL else { return }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var dest = downloads.appendingPathComponent(name)
        var counter = 1
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: localURL, to: dest)
            log("🎁 Received \(name) from \(id.displayName) → \(dest.path)")
            let savedDest = dest
            DispatchQueue.main.async {
                play("Glass")
                showToast("🎁 Screenshot from \(cleanName(id.displayName))")
                if let img = NSImage(contentsOf: savedDest) {
                    animateReceive(image: img) {
                        NSWorkspace.shared.open(savedDest)
                    }
                } else {
                    NSWorkspace.shared.open(savedDest)
                }
            }
        } catch {
            log("❌ Could not save received file: \(error)")
        }
    }
}

// MARK: - Menu bar status item

final class StatusUI: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        let peers = link.session.connectedPeers
        item.button?.title = peers.isEmpty ? "✊…" : "✊✓"

        let menu = NSMenu()
        menu.addItem(withTitle: "Slingshot v0.3", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        if peers.isEmpty {
            menu.addItem(withTitle: "Searching for nearby Macs…", action: nil, keyEquivalent: "")
        } else {
            for p in peers {
                menu.addItem(withTitle: "🤝 \(cleanName(p.displayName))", action: nil, keyEquivalent: "")
            }
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let logItem = NSMenuItem(title: "Show Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Slingshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(shotsDir)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logFileURL)
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

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw RuntimeError("No camera found")
        }
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RuntimeError("Cannot use camera input") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RuntimeError("Cannot attach video output") }
        session.addOutput(output)

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

// MARK: - Main

log("Slingshot v0.3 — palm, then fist, and your screen flies to the nearest Mac")

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

func startEverything() {
    statusUI = StatusUI()

    // Screen-recording permission: without it screencapture returns nothing useful.
    if !CGPreflightScreenCaptureAccess() {
        log("⚠️ Screen Recording permission missing — requesting now. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Slingshot.")
        showToast("⚠️ Grant Screen Recording in System Settings, then reopen Slingshot")
        CGRequestScreenCaptureAccess()
    }

    link.start()

    engine.onGrab = {
        play("Pop")
        log("✊ GRAB! Taking screenshot…")
        if let shot = takeScreenshot() {
            log("🖼  Screenshot saved: \(shot.lastPathComponent)")
            if let img = NSImage(contentsOf: shot) {
                DispatchQueue.main.async {
                    flashScreen()
                    animateGrab(image: img)
                }
            }
            link.send(shot)
        } else {
            log("❌ Screenshot failed — check Screen Recording permission")
            DispatchQueue.main.async { showToast("❌ Screenshot failed — check Screen Recording permission") }
        }
    }

    let cam = Camera { pixelBuffer in
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([handRequest])) != nil else { return }
        if let obs = handRequest.results?.first {
            let (pose, debug) = classify(obs)
            engine.update(pose: pose, debug: debug)
        } else {
            engine.update(pose: .unknown, debug: "no hand")
        }
    }
    camera = cam

    do {
        try cam.start()
    } catch {
        log("❌ Camera failed: \(error)")
        app.terminate(nil)
        return
    }

    log("🙌 Ready. Hold an open palm to the camera (~half a second), then close your fist.")
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
