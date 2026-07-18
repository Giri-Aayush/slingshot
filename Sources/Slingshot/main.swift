import AVFoundation
import AppKit
import MultipeerConnectivity
import Vision

// MARK: - Helpers

let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Slingshot.log")
let shotsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Slingshot", isDirectory: true)

let logQueue = DispatchQueue(label: "slingshot.log")
let logFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    return df
}()
let logHandle: FileHandle? = {
    let fm = FileManager.default
    if !fm.fileExists(atPath: logFileURL.path) {
        fm.createFile(atPath: logFileURL.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: logFileURL)
    handle?.seekToEndOfFile()
    return handle
}()

func log(_ msg: String) {
    let now = Date()
    logQueue.async {
        let line = "[\(logFormatter.string(from: now))] \(msg)\n"
        print(line, terminator: "")
        fflush(stdout)
        if let data = line.data(using: .utf8) {
            logHandle?.write(data)
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

/// The screenshot appears large, then shrinks toward the bottom-right corner, like it was grabbed off the screen.
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

func classify(_ obs: VNHumanHandPoseObservation) -> (pose: HandPose, wrist: CGPoint?, debug: String) {
    func point(_ j: VNHumanHandPoseObservation.JointName) -> CGPoint? {
        guard let p = try? obs.recognizedPoint(j), p.confidence > 0.25 else { return nil }
        return p.location
    }
    guard let wrist = point(.wrist), let mcp = point(.middleMCP) else { return (.unknown, nil, "no wrist/palm") }
    let handSize = hypot(wrist.x - mcp.x, wrist.y - mcp.y)
    guard handSize > 0.02 else { return (.unknown, wrist, "hand too small") }

    let tips: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
    var extended = 0
    var curled = 0
    var reaches: [String] = []
    for tip in tips {
        if let p = point(tip) {
            let reach = hypot(p.x - wrist.x, p.y - wrist.y) / handSize
            reaches.append(String(format: "%.2f", reach))
            if reach > 1.5 { extended += 1 } else if reach < 1.3 { curled += 1 }
        } else {
            // A fingertip Vision cannot see on a detected hand is usually curled into the palm.
            curled += 1
            reaches.append("hidden")
        }
    }
    let debug = "ext=\(extended) curl=\(curled) reach=[\(reaches.joined(separator: " "))]"
    if extended == 4 { return (.open, wrist, debug) }
    if extended == 0 && curled >= 2 { return (.fist, wrist, debug) }
    return (.unknown, wrist, debug)
}

// MARK: - Gesture state machine

final class GestureEngine {
    var onGrab: () -> Void = {}
    var onRelease: () -> Void = {}       // sustained fist, then open hand: the "drop" gesture
    var onReleasePrimed: () -> Void = {} // the fist half of a drop is complete
    var onGrabSuppressed: () -> Void = {} // user shows a palm while grabbing is paused
    var grabAllowed: () -> Bool = { true }
    var releaseAllowed: () -> Bool = { true }
    var debugLogging = true

    // ~15 processed frames per second. A few off-frames (grace) are tolerated
    // before a streak resets, since Vision drops frames during transitions.
    private let armNeeded = 30          // 2 s of steady open palm to arm
    private let grabNeeded = 15         // 1 s of steady fist to grab
    private let releaseFistNeeded = 15  // 1 s of steady fist to prime a drop
    private let releaseOpenNeeded = 8   // then 0.5 s of open hand to drop
    private let grace = 4
    private let armTimeout: TimeInterval = 6
    private let releaseWindow: TimeInterval = 3
    private let cooldown: TimeInterval = 2
    private let maxWristJump: CGFloat = 0.08  // per frame, in normalized image space

    private struct Streak {
        var count = 0
        private var miss = 0
        private let grace: Int
        init(grace: Int) { self.grace = grace }
        mutating func hit() { count += 1; miss = 0 }
        mutating func neutral() { miss += 1; if miss > grace { reset() } }
        mutating func reset() { count = 0; miss = 0 }
    }

    private var lastPose: HandPose = .unknown
    private var lastWrist: CGPoint?

    private var openStreak: Streak
    private var fistStreak: Streak
    private var armed = false
    private var armedAt = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var announcedReady = true

    private var relFist: Streak
    private var relOpen: Streak
    private var relPrimedAt: Date?
    private var relCooldownUntil = Date.distantPast

    private var suppressedOpen = 0
    private var suppressNoticeAfter = Date.distantPast

    init() {
        openStreak = Streak(grace: grace)
        fistStreak = Streak(grace: grace)
        relFist = Streak(grace: grace)
        relOpen = Streak(grace: grace)
    }

    func update(pose: HandPose, wrist: CGPoint?, debug: String = "") {
        let now = Date()
        if debugLogging, pose != lastPose {
            log("   · pose → \(pose) (\(debug))")
        }
        lastPose = pose

        // A jumping wrist is a moving or waving hand. Deliberate gestures hold still,
        // so movement resets the timers instead of counting toward them.
        var steady = true
        if let w = wrist, let l = lastWrist {
            steady = hypot(w.x - l.x, w.y - l.y) <= maxWristJump
        }
        lastWrist = wrist

        updateRelease(pose: pose, steady: steady, now: now)
        updateGrab(pose: pose, steady: steady, now: now)
    }

    private func updateGrab(pose: HandPose, steady: Bool, now: Date) {
        guard now >= cooldownUntil else { return }
        if !announcedReady {
            announcedReady = true
            log("🔄 Ready. Show your palm to grab again")
        }

        if armed {
            if now.timeIntervalSince(armedAt) > armTimeout {
                log("⌛️ Gesture timed out. Show your palm again")
                disarm()
                return
            }
            if !grabAllowed() {
                disarm()  // a hold or pending catch took over; stand down quietly
                return
            }
            switch pose {
            case .fist:
                if steady { fistStreak.hit() } else { fistStreak.reset() }
                if fistStreak.count >= grabNeeded {
                    disarm()
                    cooldownUntil = now.addingTimeInterval(cooldown)
                    announcedReady = false
                    onGrab()
                }
            case .open:
                armedAt = now  // palm still showing: stay armed
                fistStreak.reset()
            case .unknown:
                fistStreak.neutral()
            }
        } else {
            if pose == .open && !grabAllowed() {
                openStreak.reset()
                suppressedOpen += 1
                if suppressedOpen >= 15, now >= suppressNoticeAfter {
                    suppressNoticeAfter = now.addingTimeInterval(10)
                    onGrabSuppressed()
                }
            } else if pose == .open && steady {
                suppressedOpen = 0
                openStreak.hit()
                if openStreak.count >= armNeeded {
                    armed = true
                    armedAt = now
                    openStreak.reset()
                    play("Tink")
                    log("✋ Armed. Hold your fist for one second to grab")
                }
            } else if pose == .open {
                openStreak.reset()  // moving palm: start over
            } else {
                suppressedOpen = 0
                openStreak.neutral()
            }
        }
    }

    private func updateRelease(pose: HandPose, steady: Bool, now: Date) {
        // The release detector only runs while a peer's hold is pending. This keeps
        // a grab's own fist from priming a release, so grab and catch never overlap.
        guard releaseAllowed() else {
            relFist.reset()
            relOpen.reset()
            relPrimedAt = nil
            return
        }
        if let primed = relPrimedAt {
            if now.timeIntervalSince(primed) > releaseWindow {
                relPrimedAt = nil
                relOpen.reset()
                return
            }
            switch pose {
            case .open:
                relOpen.hit()
                if relOpen.count >= releaseOpenNeeded {
                    relPrimedAt = nil
                    relOpen.reset()
                    relCooldownUntil = now.addingTimeInterval(cooldown)
                    onRelease()
                }
            case .fist:
                relOpen.reset()
                relPrimedAt = now  // still holding the fist: keep the window fresh
            case .unknown:
                relOpen.neutral()
            }
        } else {
            guard now >= relCooldownUntil else { return }
            switch pose {
            case .fist:
                if steady { relFist.hit() } else { relFist.reset() }
                if relFist.count >= releaseFistNeeded {
                    relFist.reset()
                    relPrimedAt = now
                    onReleasePrimed()
                }
            case .open:
                relFist.neutral()
            case .unknown:
                relFist.neutral()
            }
        }
    }

    private func disarm() {
        armed = false
        openStreak.reset()
        fistStreak.reset()
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
    private var retryTimer: Timer?

    private let holdWindow: TimeInterval = 30
    private let postCatchMute: TimeInterval = 5

    // All mutable state below is guarded by `lock`. It is touched from three
    // contexts: MultipeerConnectivity's private delegate queue, the camera queue
    // (via the gesture engine's callbacks), and main-queue expiry closures.
    // Never call out (send, UI, log) while holding the lock.
    private let lock = NSLock()
    private var discovered: Set<MCPeerID> = []
    private var heldFile: URL?
    private var holdGeneration = 0
    private var lastHoldEnd = "caught"
    private var remoteHolders: [MCPeerID: Date] = [:]
    private var grabMutedUntil = Date.distantPast

    var isHolding: Bool { lock.withLock { heldFile != nil } }
    var grabMuted: Bool { lock.withLock { Date() < grabMutedUntil } }
    var hasRemoteHold: Bool {
        let now = Date()
        return lock.withLock { remoteHolders.values.contains { now < $0 } }
    }
    var nearbyPeers: [MCPeerID] {
        let connected = session.connectedPeers
        return lock.withLock { discovered.filter { !connected.contains($0) } }
            .sorted { $0.displayName < $1.displayName }
    }

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
        let connected = session.connectedPeers
        let candidates = lock.withLock {
            discovered.filter { !connected.contains($0) && shouldInvite($0) }
        }
        for id in candidates {
            log("🔁 Retrying connection to \(id.displayName)…")
            browser.invitePeer(id, to: session, withContext: nil, timeout: 15)
        }
    }

    // MARK: Hold / catch protocol

    /// Grab: keep the screenshot in the fist. Nothing is sent until a peer catches it.
    func hold(_ url: URL) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            log("📦 No peer connected. Screenshot saved locally at \(url.path)")
            DispatchQueue.main.async { showToast("📦 No Mac connected. Saved to Pictures/Slingshot") }
            return
        }
        let gen: Int = lock.withLock {
            heldFile = url
            holdGeneration += 1
            return holdGeneration
        }
        sendControl(["t": "hold"])
        log("✊ Holding \(url.lastPathComponent). At the receiving Mac: fist for 1 second, then open your hand. Expires in \(Int(holdWindow)) s")
        DispatchQueue.main.async {
            showToast("✊ Holding screenshot. At the other Mac: fist for 1 second, then open your hand")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdWindow) { [weak self] in
            guard let self else { return }
            let expired: Bool = self.lock.withLock {
                guard self.holdGeneration == gen, self.heldFile != nil else { return false }
                self.heldFile = nil
                self.lastHoldEnd = "expired"
                return true
            }
            guard expired else { return }
            self.sendControl(["t": "unhold"])
            log("⌛️ Hold expired. Screenshot saved locally")
            showToast("⌛️ Hold expired. Screenshot saved locally")
        }
    }

    /// A deliberate fist-then-open at this Mac's camera: catch the freshest live hold.
    func catchGesture() {
        let connected = session.connectedPeers
        let holder: MCPeerID? = lock.withLock {
            let now = Date()
            remoteHolders = remoteHolders.filter { now < $0.value && connected.contains($0.key) }
            guard let best = remoteHolders.max(by: { $0.value < $1.value })?.key else { return nil }
            remoteHolders[best] = nil
            grabMutedUntil = Date().addingTimeInterval(postCatchMute)
            return best
        }
        guard let holder else { return }
        log("🫳 Catch! Requesting the screenshot from \(holder.displayName)")
        DispatchQueue.main.async {
            play("Tink")
            showToast("🫳 Catching…")
        }
        if !sendControl(["t": "catch"], to: [holder]) {
            lock.withLock { grabMutedUntil = Date.distantPast }
            log("❌ Catch failed. \(holder.displayName) is unreachable")
            DispatchQueue.main.async { showToast("❌ Catch failed. The holding Mac is unreachable") }
        }
    }

    @discardableResult
    private func sendControl(_ dict: [String: String], to peers: [MCPeerID]? = nil) -> Bool {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty, let data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        do {
            try session.send(data, toPeers: targets, with: .reliable)
            return true
        } catch {
            log("⚠️ Control message did not send: \(error.localizedDescription)")
            return false
        }
    }

    private func deliver(_ url: URL, to peer: MCPeerID) {
        let sender = (Host.current().localizedName ?? "Mac")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let name = "from-\(sender)-\(url.lastPathComponent)"
        log("🚀 Beaming \(name) to \(peer.displayName)…")
        session.sendResource(at: url, withName: name, toPeer: peer) { error in
            if let error {
                log("❌ Send to \(peer.displayName) failed: \(error.localizedDescription)")
                DispatchQueue.main.async { showToast("❌ Send failed: \(error.localizedDescription)") }
            } else {
                log("✅ Delivered to \(peer.displayName)")
                DispatchQueue.main.async {
                    showToast("✅ Dropped on \(cleanName(peer.displayName))")
                    play("Purr")
                }
            }
        }
    }

    // MARK: Browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer id: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        log("🔍 Found peer \(id.displayName)")
        lock.withLock { _ = discovered.insert(id) }
        DispatchQueue.main.async { statusUI?.refresh() }
        if shouldInvite(id) {
            browser.invitePeer(id, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
        log("👋 Lost sight of \(id.displayName)")
        lock.withLock { _ = discovered.remove(id) }
        DispatchQueue.main.async { statusUI?.refresh() }
    }

    // MARK: Advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer id: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        log("📨 Invitation from \(id.displayName), accepting")
        invitationHandler(true, session)
    }

    // MARK: Session

    func session(_ session: MCSession, peer id: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connecting:
            log("…  Connecting to \(id.displayName)")
        case .connected:
            log("🤝 Connected to \(id.displayName). Ready to beam")
            DispatchQueue.main.async {
                play("Hero")
                showToast("🤝 Connected to \(cleanName(id.displayName))")
                statusUI?.refresh()
            }
        case .notConnected:
            log("🔌 Disconnected from \(id.displayName)")
            lock.withLock { remoteHolders[id] = nil }
            DispatchQueue.main.async { statusUI?.refresh() }
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let type = dict["t"] else { return }
        switch type {
        case "hold":
            lock.withLock { remoteHolders[id] = Date().addingTimeInterval(holdWindow + 2) }
            log("🫴 \(id.displayName) is holding a screenshot. Hold a fist for 1 second, then open your hand to catch it here")
            DispatchQueue.main.async {
                play("Tink")
                showToast("🫴 \(cleanName(id.displayName)) is holding a screenshot. Fist for 1 second, then open, to catch it here")
            }
        case "unhold":
            lock.withLock { remoteHolders[id] = nil }
        case "catch":
            let url: URL? = lock.withLock {
                guard let u = heldFile else { return nil }
                heldFile = nil
                holdGeneration += 1
                lastHoldEnd = "caught"
                return u
            }
            if let url {
                sendControl(["t": "unhold"])  // the hold is spoken for; stand everyone down
                log("🎯 \(id.displayName) caught it. Sending")
                deliver(url, to: id)
            } else {
                let why = lock.withLock { lastHoldEnd }
                sendControl(["t": "late", "why": why], to: [id])
            }
        case "late":
            let why = dict["why"] == "expired" ? "The hold expired" : "Someone else caught it first"
            log("🐢 Too late. \(why)")
            DispatchQueue.main.async { showToast("🐢 Too late. \(why)") }
        default:
            break
        }
    }

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
        lock.withLock { grabMutedUntil = Date().addingTimeInterval(postCatchMute) }
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
        let connected = link.session.connectedPeers.sorted { $0.displayName < $1.displayName }
        let nearby = link.nearbyPeers
        item.button?.title = connected.isEmpty ? "✊…" : "✊ \(connected.count)"

        let menu = NSMenu()
        menu.addItem(withTitle: "Slingshot v0.8", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        if connected.isEmpty && nearby.isEmpty {
            menu.addItem(withTitle: "Searching for nearby Macs…", action: nil, keyEquivalent: "")
        }
        if !connected.isEmpty {
            menu.addItem(withTitle: "Connected (\(connected.count))", action: nil, keyEquivalent: "")
            for p in connected {
                menu.addItem(withTitle: "  🤝 \(cleanName(p.displayName))", action: nil, keyEquivalent: "")
            }
        }
        if !nearby.isEmpty {
            menu.addItem(withTitle: "Nearby, connecting…", action: nil, keyEquivalent: "")
            for p in nearby {
                menu.addItem(withTitle: "  🔍 \(cleanName(p.displayName))", action: nil, keyEquivalent: "")
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

log("Slingshot v0.8. Palm, then fist, and your screen flies to the nearest Mac")

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
        log("⚠️ Screen Recording permission missing. Requesting now. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Slingshot.")
        showToast("⚠️ Grant Screen Recording in System Settings, then reopen Slingshot")
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
        DispatchQueue.main.async { showToast("⏸️ Grab paused while a hold is pending") }
    }

    engine.onRelease = {
        link.catchGesture()
    }

    engine.onReleasePrimed = {
        play("Tink")
        log("👊 Fist seen. Open your hand to drop it here")
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
                link.hold(shot)
            } else {
                log("❌ Screenshot failed. Check Screen Recording permission")
                DispatchQueue.main.async { showToast("❌ Screenshot failed. Check Screen Recording permission") }
            }
        }
    }

    let cam = Camera { pixelBuffer in
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([handRequest])) != nil else { return }
        if let obs = handRequest.results?.first {
            let (pose, wrist, debug) = classify(obs)
            engine.update(pose: pose, wrist: wrist, debug: debug)
        } else {
            engine.update(pose: .unknown, wrist: nil, debug: "no hand")
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

    log("🙌 Ready. Hold your palm open and still for 2 seconds, then hold your fist for 1 second to grab.")
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
