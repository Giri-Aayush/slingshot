import AppKit
import MultipeerConnectivity
import Vision

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
    private var discovered: [MCPeerID: String] = [:]  // peer -> install ID
    private var trustedIDs = Set(UserDefaults.standard.stringArray(forKey: "trustedPeers") ?? [])
    private var deniedIDs: Set<String> = []       // this session only
    private var pendingApproval: Set<String> = []
    private var heldFile: URL?
    private var holdGeneration = 0
    private var lastHoldEnd = "caught"
    struct RemoteHold {
        let deadline: Date
        let mode: TransferMode
        let face: VNFeaturePrintObservation?
    }

    private var remoteHolders: [MCPeerID: RemoteHold] = [:]
    private var grabMutedUntil = Date.distantPast
    private var transfersActive = 0

    var isHolding: Bool { lock.withLock { heldFile != nil } }
    var grabMuted: Bool { lock.withLock { Date() < grabMutedUntil || transfersActive > 0 } }
    var hasActiveTransfers: Bool { lock.withLock { transfersActive > 0 } }
    var hasRemoteHold: Bool {
        let now = Date()
        return lock.withLock { remoteHolders.values.contains { now < $0.deadline } }
    }
    var nearbyPeers: [MCPeerID] {
        let connected = session.connectedPeers
        return lock.withLock { Array(discovered.keys).filter { !connected.contains($0) } }
            .sorted { $0.displayName < $1.displayName }
    }

    override init() {
        let host = Host.current().localizedName ?? "Mac"
        // Random suffix so two identically named MacBooks never collide.
        peerID = MCPeerID(displayName: "\(host)#\(Int.random(in: 100...999))")
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["iid": installID], serviceType: Self.serviceType)
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
            discovered.filter { trustedIDs.contains($0.value) && !connected.contains($0.key) && shouldInvite($0.key) }
                .map { $0.key }
        }
        for id in candidates {
            log("🔁 Retrying connection to \(id.displayName)…")
            invite(id)
        }
    }

    // MARK: Trust

    private func invite(_ id: MCPeerID) {
        let context = try? JSONSerialization.data(withJSONObject: ["iid": installID])
        browser.invitePeer(id, to: session, withContext: context, timeout: 15)
    }

    /// Prompt the user about a first-contact Mac. Serialized by the main queue.
    private func requestApproval(name: String, verb: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(name) \(verb)"
            alert.informativeText = "Slingshot Macs exchange files with hand gestures. Allow only Macs you recognize. Approvals persist; you can reset trusted Macs from the menu bar."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// trusted, denied, pending, or ask (marking it pending)
    private func trustStatus(of iid: String) -> String {
        lock.withLock {
            if trustedIDs.contains(iid) { return "trusted" }
            if deniedIDs.contains(iid) { return "denied" }
            if pendingApproval.contains(iid) { return "pending" }
            pendingApproval.insert(iid)
            return "ask"
        }
    }

    private func resolveApproval(iid: String, allowed: Bool) {
        lock.withLock {
            pendingApproval.remove(iid)
            if allowed { trustedIDs.insert(iid) } else { deniedIDs.insert(iid) }
        }
        if allowed {
            UserDefaults.standard.set(Array(lock.withLock { trustedIDs }), forKey: "trustedPeers")
        }
    }

    func resetTrust() {
        lock.withLock {
            trustedIDs.removeAll()
            deniedIDs.removeAll()
            pendingApproval.removeAll()
        }
        UserDefaults.standard.removeObject(forKey: "trustedPeers")
        log("🧹 Trusted Macs reset. Next contact will ask again")
    }

    // MARK: Hold / catch protocol

    /// Grab: keep the screenshot in the fist. Nothing is sent until a peer catches it.
    func hold(_ url: URL, mode: TransferMode, ownerFace: String?) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            log("📦 No peer connected. Screenshot saved locally at \(url.path)")
            DispatchQueue.main.async {
                NotchIsland.shared.compact("wifi.slash", NotchIsland.Palette.ash, "No Macs", kind: .outcome)
            }
            return
        }
        let gen: Int = lock.withLock {
            heldFile = url
            holdGeneration += 1
            return holdGeneration
        }
        var msg = ["t": "hold", "mode": mode.rawValue]
        if let ownerFace { msg["face"] = ownerFace }
        sendControl(msg)
        let lockNote = (mode == .normal && ownerFace != nil) ? " Locked to your face." : ""
        log("✊ Holding \(url.lastPathComponent).\(lockNote) At the receiving Mac: fist for 1 second, then open your hand. Expires in \(Int(holdWindow)) s")
        DispatchQueue.main.async {
            let isShot = url.path.hasPrefix(shotsDir.path)
            let thumb = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            NotchIsland.shared.tray(image: thumb, symbol: "square.and.arrow.up.fill",
                                    tint: NotchIsland.Palette.ice,
                                    title: isShot ? "Holding screenshot" : "Holding \(url.lastPathComponent)",
                                    subtitle: "Fist 1 second, then open your hand at another Mac",
                                    deadline: Date().addingTimeInterval(self.holdWindow), total: self.holdWindow,
                                    persist: true)
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
            NotchIsland.shared.clearPersist()
            NotchIsland.shared.compact("hourglass", NotchIsland.Palette.ash, "Expired", kind: .outcome)
            scheduleWorkDoneSleep()
        }
    }

    /// A deliberate fist-then-open at this Mac's camera: catch the freshest live hold.
    /// Normal-mode holds carry the grabber's face print; the catch only completes when
    /// this Mac's camera sees a matching face. Best effort, not a security boundary.
    func catchGesture() {
        let connected = session.connectedPeers
        let now = Date()
        // Peek without consuming: face verification is slow and must run outside the lock.
        let candidate: (peer: MCPeerID, hold: RemoteHold)? = lock.withLock {
            remoteHolders = remoteHolders.filter { now < $0.value.deadline && connected.contains($0.key) }
            return remoteHolders.max(by: { $0.value.deadline < $1.value.deadline }).map { ($0.key, $0.value) }
        }
        guard let (peer, hold) = candidate else { return }

        if hold.mode == .normal, let ownerFace = hold.face {
            guard let frame = frameStore.latest(), let myFace = FaceID.faceprint(from: frame) else {
                log("🙈 No face visible here. Face the camera, then fist and open to catch")
                DispatchQueue.main.async {
                    NotchIsland.shared.compact("person.crop.circle.badge.questionmark", NotchIsland.Palette.amber, "Show face", kind: .prompt, pulsing: true)
                }
                return
            }
            if let dist = FaceID.distance(ownerFace, myFace) {
                log(String(format: "   · face distance %.3f (match if at most %.2f)", dist, faceMatchThreshold))
                if dist > faceMatchThreshold {
                    log("🚫 Different person. Normal mode blocks this drop")
                    DispatchQueue.main.async {
                        play("Basso")
                        NotchIsland.shared.compact("person.crop.circle.badge.xmark", NotchIsland.Palette.coral, "Blocked", kind: .outcome)
                    }
                    return
                }
                log("✅ Face matches the grabber")
            } else {
                // Prints from different Vision revisions are incomparable (mixed macOS
                // versions). Let the transfer through rather than dead-ending it, and say so.
                log("⚠️ Face prints incomparable across these Macs. Allowing the catch")
            }
        }

        let claimed: Bool = lock.withLock {
            guard remoteHolders[peer] != nil else { return false }
            remoteHolders[peer] = nil
            grabMutedUntil = Date().addingTimeInterval(postCatchMute)
            return true
        }
        guard claimed else { return }
        log("🫳 Catch! Requesting the screenshot from \(peer.displayName)")
        DispatchQueue.main.async {
            play("Tink")
            NotchIsland.shared.clearPersist()
            NotchIsland.shared.compact("arrow.down.circle.fill", NotchIsland.Palette.mint, "Catching")
        }
        if !sendControl(["t": "catch"], to: [peer]) {
            lock.withLock { grabMutedUntil = Date.distantPast }
            log("❌ Catch failed. \(peer.displayName) is unreachable")
            DispatchQueue.main.async {
                NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Unreachable", kind: .outcome)
            }
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
        lock.withLock { transfersActive += 1 }
        let progress = session.sendResource(at: url, withName: name, toPeer: peer) { [weak self] error in
            self?.lock.withLock {
                if let self { self.transfersActive = max(0, self.transfersActive - 1) }
            }
            DispatchQueue.main.async { NotchIsland.shared.endTransfer() }
            if let error {
                log("❌ Send to \(peer.displayName) failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Send failed", kind: .outcome)
                }
            } else {
                log("✅ Delivered to \(peer.displayName)")
                DispatchQueue.main.async {
                    NotchIsland.shared.compact("checkmark.seal.fill", NotchIsland.Palette.mint, "Sent", kind: .outcome)
                    play("Purr")
                }
            }
            scheduleWorkDoneSleep()
        }
        // Screenshots finish in a blink; only long transfers earn the progress tray.
        if let progress {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !progress.isFinished, !progress.isCancelled else { return }
                let thumb = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
                NotchIsland.shared.transferTray(image: thumb, symbol: "arrow.up.circle.fill",
                                                tint: NotchIsland.Palette.ice,
                                                title: "Sending to \(cleanName(peer.displayName))",
                                                subtitle: url.lastPathComponent, progress: progress)
            }
        }
    }


    // MARK: Browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer id: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        log("🔍 Found peer \(id.displayName)")
        let iid = info?["iid"] ?? "legacy:" + cleanName(id.displayName)
        lock.withLock { discovered[id] = iid }
        DispatchQueue.main.async { statusUI?.refresh() }
        switch trustStatus(of: iid) {
        case "trusted":
            if shouldInvite(id) { invite(id) }
        case "ask":
            requestApproval(name: cleanName(id.displayName), verb: "is nearby and can join your Slingshot room") { [weak self] allowed in
                guard let self else { return }
                self.resolveApproval(iid: iid, allowed: allowed)
                if allowed {
                    log("✅ \(id.displayName) trusted")
                    if self.shouldInvite(id) { self.invite(id) }
                } else {
                    log("🚫 \(id.displayName) denied for this session")
                }
            }
        default:
            break
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
        log("👋 Lost sight of \(id.displayName)")
        lock.withLock { _ = discovered.removeValue(forKey: id) }
        DispatchQueue.main.async { statusUI?.refresh() }
    }

    // MARK: Advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer id: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let iid: String
        if let context,
           let dict = try? JSONSerialization.jsonObject(with: context) as? [String: String],
           let sent = dict["iid"] {
            iid = sent
        } else {
            iid = "legacy:" + cleanName(id.displayName)
        }
        switch trustStatus(of: iid) {
        case "trusted":
            log("📨 Invitation from \(id.displayName), trusted, accepting")
            invitationHandler(true, session)
        case "denied":
            invitationHandler(false, nil)
        case "ask":
            log("📨 Invitation from \(id.displayName), asking you")
            requestApproval(name: cleanName(id.displayName), verb: "wants to connect") { [weak self] allowed in
                self?.resolveApproval(iid: iid, allowed: allowed)
                log(allowed ? "✅ \(id.displayName) trusted" : "🚫 \(id.displayName) denied for this session")
                invitationHandler(allowed, allowed ? self?.session : nil)
            }
        default:
            invitationHandler(false, nil)
        }
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
                NotchIsland.shared.compact("person.2.fill", NotchIsland.Palette.ice, "Connected")
                statusUI?.refresh()
            }
        case .notConnected:
            log("🔌 Disconnected from \(id.displayName)")
            let anyLeft: Bool = lock.withLock {
                remoteHolders[id] = nil
                let now = Date()
                return remoteHolders.values.contains { now < $0.deadline }
            }
            let orphaned: Bool = lock.withLock {
                if session.connectedPeers.isEmpty && transfersActive > 0 {
                    transfersActive = 0
                    return true
                }
                return false
            }
            if orphaned {
                log("⚠️ Transfers orphaned by disconnect. Resetting")
                DispatchQueue.main.async { NotchIsland.shared.endTransfer() }
            }
            if !anyLeft { scheduleWorkDoneSleep() }
            DispatchQueue.main.async {
                if !anyLeft { NotchIsland.shared.clearPersist() }
                statusUI?.refresh()
            }
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let type = dict["t"] else { return }
        switch type {
        case "hold":
            // Peers that predate modes send no mode field; treat them as unlocked.
            let mode = TransferMode(rawValue: dict["mode"] ?? "pro") ?? .pro
            let face = dict["face"].flatMap(FaceID.decode)
            lock.withLock {
                remoteHolders[id] = RemoteHold(deadline: Date().addingTimeInterval(holdWindow + 2),
                                               mode: mode, face: face)
            }
            DispatchQueue.main.async { wakeCamera("incoming hold") }
            log("🫴 \(id.displayName) is holding a screenshot. Hold a fist for 1 second, then open your hand to catch it here")
            DispatchQueue.main.async {
                play("Tink")
                NotchIsland.shared.tray(image: nil, symbol: "tray.and.arrow.down.fill",
                                        tint: NotchIsland.Palette.mint,
                                        title: "\(cleanName(id.displayName)) is holding",
                                        subtitle: "Fist 1 second, then open your hand to catch",
                                        deadline: Date().addingTimeInterval(30), total: 30, persist: true)
            }
        case "unhold":
            let anyLeft: Bool = lock.withLock {
                remoteHolders[id] = nil
                let now = Date()
                return remoteHolders.values.contains { now < $0.deadline }
            }
            if !anyLeft {
                DispatchQueue.main.async { NotchIsland.shared.clearPersist() }
                scheduleWorkDoneSleep()
            }
        case "catch":
            let url: URL? = lock.withLock {
                guard let u = heldFile else { return nil }
                heldFile = nil
                holdGeneration += 1
                lastHoldEnd = "caught"
                return u
            }
            if let url {
                let others = session.connectedPeers.filter { $0 != id }
                if !others.isEmpty { sendControl(["t": "unhold"], to: others) }
                log("🎯 \(id.displayName) caught it. Sending")
                DispatchQueue.main.async { NotchIsland.shared.clearPersist() }
                deliver(url, to: id)
            } else {
                let why = lock.withLock { lastHoldEnd }
                sendControl(["t": "late", "why": why], to: [id])
            }
        case "late":
            let why = dict["why"] == "expired" ? "The hold expired" : "Someone else caught it first"
            log("🐢 Too late. \(why)")
            DispatchQueue.main.async {
                NotchIsland.shared.compact("tortoise.fill", NotchIsland.Palette.coral, "Too late", kind: .outcome)
            }
        default:
            break
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer id: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName name: String,
                 fromPeer id: MCPeerID, with progress: Progress) {
        log("📥 Receiving \(name) from \(id.displayName)…")
        lock.withLock { transfersActive += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !progress.isFinished, !progress.isCancelled else { return }
            NotchIsland.shared.transferTray(image: nil, symbol: "arrow.down.circle.fill",
                                            tint: NotchIsland.Palette.mint,
                                            title: "Receiving from \(cleanName(id.displayName))",
                                            subtitle: name, progress: progress)
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String,
                 fromPeer id: MCPeerID, at localURL: URL?, withError error: Error?) {
        lock.withLock { transfersActive = max(0, transfersActive - 1) }
        DispatchQueue.main.async { NotchIsland.shared.endTransfer() }
        if let error {
            log("❌ Receive failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Receive failed", kind: .outcome)
            }
            scheduleWorkDoneSleep()
            return
        }
        guard let localURL else {
            scheduleWorkDoneSleep()
            return
        }
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
                NotchIsland.shared.tray(image: NSImage(contentsOf: savedDest), symbol: "checkmark.seal.fill",
                                        tint: NotchIsland.Palette.mint,
                                        title: "From \(cleanName(id.displayName))",
                                        subtitle: "Saved to Downloads",
                                        deadline: nil, total: 0, persist: false)
                let imageExts = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]
                if imageExts.contains(savedDest.pathExtension.lowercased()),
                   let img = NSImage(contentsOf: savedDest) {
                    animateReceive(image: img) {
                        NSWorkspace.shared.open(savedDest)
                    }
                } else {
                    // Never launch arbitrary received files; show them instead.
                    NSWorkspace.shared.activateFileViewerSelecting([savedDest])
                }
            }
        } catch {
            log("❌ Could not save received file: \(error)")
        }
        scheduleWorkDoneSleep()
    }
}

