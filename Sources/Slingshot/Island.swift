import AppKit

// MARK: - Notch island

/// The Slingshot Dynamic Island, per the v1.0 design specification.
///
/// Layout laws: nothing renders inside the physical notch band; compact content
/// lives in the wings, tray content in the band below. Collapsed draws nothing.
/// Tint is reserved for the compact word, glyphs, ring, and badges; body text is
/// white or gray. Every tray is one fixed width (trayWidth) so states never jitter.
///
/// Transients come in three classes with an interrupt order: outcome beats
/// prompt beats status. Standing trays (holds) sit underneath and resume when
/// a transient ends. Prompts pulse their glyph; states never pulse.

/// An invisible window covering exactly the physical notch. The notch is dead
/// pixels, so it can accept mouse hover and file drops without stealing a
/// single click from real UI.
private final class NotchSensorView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onDragEnter: () -> Void = {}
    var onDrop: (URL) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onExit() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = NSURL(from: sender.draggingPasteboard) as URL? else { return false }
        onDrop(url)
        return true
    }
}

enum IslandClass: Int {
    case status = 1   // Armed, Connected, Catching, awake eye, hover peek
    case prompt = 2   // Open hand, Show face, Snap to wake, Drop to hold
    case outcome = 3  // Sent, Copied, Received, Blocked, Too late, Expired, failures

    var dwell: TimeInterval {
        switch self {
        case .status: return 1.8
        case .prompt: return 2.6
        case .outcome: return 2.4
        }
    }
}

final class NotchIsland {
    static let shared = NotchIsland()

    enum Palette {
        static let amber = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.20, alpha: 1)
        static let ice   = NSColor(calibratedRed: 0.35, green: 0.85, blue: 1.00, alpha: 1)
        static let mint  = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.55, alpha: 1)
        static let coral = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.38, alpha: 1)
        static let ash   = NSColor(white: 0.78, alpha: 1)
    }

    private enum Face {
        case compact(symbol: String?, tint: NSColor, word: String, pulsing: Bool)
        case tray(image: NSImage?, symbol: String?, tint: NSColor,
                  title: String, subtitle: String, deadline: Date?, total: TimeInterval)
        case progressTray(image: NSImage?, symbol: String?, tint: NSColor,
                          title: String, subtitle: String, progress: Progress)
    }

    private let window: NSWindow
    private let canvas = NSView()

    // The slab: three synchronized path layers (deep shadow, contact shadow,
    // black fill) plus a gradient hairline masked to the outline.
    private let deepShadow = CAShapeLayer()
    private let contactShadow = CAShapeLayer()
    private let slab = CAShapeLayer()
    private let hairline = CAGradientLayer()
    private let hairlineMask = CAShapeLayer()
    private var pathLayers: [CAShapeLayer] { [deepShadow, contactShadow, slab, hairlineMask] }

    private let beadRow = CALayer()
    private var beads: [CALayer] = []

    // Compact face: wings beside the notch.
    private let wingView = NSView()
    private let wingIcon = NSImageView()
    private let wingLabel = NSTextField(labelWithString: "")

    // Tray face: panel below the notch, always trayWidth wide.
    private let trayView = NSView()
    private let trayThumb = NSView()
    private let trayWell = NSView()
    private let trayWellIcon = NSImageView()
    private let trayTitle = NSTextField(labelWithString: "")
    private let traySub = NSTextField(labelWithString: "")
    private let ringView = NSView()
    private let ringTrack = CAShapeLayer()
    private let ringArc = CAShapeLayer()
    private let ringNumeral = NSTextField(labelWithString: "")
    private var ringTimer: Timer?
    private var ringDeadline: Date?
    private var ringTint: NSColor = Palette.ice
    private var progressObservation: NSKeyValueObservation?

    private var collapseWork: DispatchWorkItem?
    private var persistentFace: Face?
    private var connectedCount = 0
    private var expanded = false
    private var hovering = false
    private var transientRank = 0
    private var transientUntil = Date.distantPast
    private var sensorWindow: NSWindow?
    private let sensorView = NotchSensorView()

    /// Supplies the hover tray's content. Set by the app layer.
    var statusProvider: () -> (title: String, subtitle: String) = { ("Slingshot", "") }
    /// A file was dropped on the notch. Set by the app layer.
    var onDropFile: (URL) -> Void = { _ in }

    private let trayBand: CGFloat = 80
    private let trayWidth: CGFloat = 380
    private let canvasWidth: CGFloat = 800
    private let canvasHeight: CGFloat = 140
    private let topFlare: CGFloat = 8

    private var notchWidth: CGFloat = 200
    private var notchHeight: CGFloat = 32
    private var slabTop: CGFloat = 140
    private var hasNotch = false

    private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    private init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        canvas.wantsLayer = true
        window.contentView = canvas

        // Two-part shadow: soft ambient depth plus a tight contact line.
        deepShadow.fillColor = NSColor.black.cgColor
        deepShadow.shadowColor = NSColor.black.cgColor
        deepShadow.shadowRadius = 18
        deepShadow.shadowOpacity = 0.35
        deepShadow.shadowOffset = CGSize(width: 0, height: -6)
        contactShadow.fillColor = NSColor.black.cgColor
        contactShadow.shadowColor = NSColor.black.cgColor
        contactShadow.shadowRadius = 3
        contactShadow.shadowOpacity = 0.6
        contactShadow.shadowOffset = CGSize(width: 0, height: -1)
        slab.fillColor = NSColor.black.cgColor

        // Gradient hairline: faint against the menu bar, brighter where the
        // slab's lower edge meets the wallpaper.
        hairline.colors = [NSColor.white.withAlphaComponent(0.06).cgColor,
                           NSColor.white.withAlphaComponent(0.22).cgColor]
        hairline.startPoint = CGPoint(x: 0.5, y: 1)
        hairline.endPoint = CGPoint(x: 0.5, y: 0)
        hairlineMask.fillColor = NSColor.clear.cgColor
        hairlineMask.strokeColor = NSColor.black.cgColor
        hairlineMask.lineWidth = 1
        hairline.mask = hairlineMask

        for layer in [deepShadow, contactShadow, slab, hairline] {
            canvas.layer?.addSublayer(layer)
        }
        setSlabVisible(false)

        // Peer beads at the notch's bottom edge, one per connected Mac.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.45
        breathe.toValue = 0.8
        breathe.duration = 3.0
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        beadRow.add(breathe, forKey: "breathe")
        canvas.layer?.addSublayer(beadRow)

        // Compact wings
        wingView.alphaValue = 0
        wingIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        wingLabel.font = roundedFont(11, .semibold)
        wingLabel.alignment = .right
        wingLabel.lineBreakMode = .byClipping
        wingView.addSubview(wingIcon)
        wingView.addSubview(wingLabel)
        canvas.addSubview(wingView)

        // Tray panel
        trayView.alphaValue = 0
        trayThumb.wantsLayer = true
        trayThumb.layer?.cornerRadius = 8
        trayThumb.layer?.cornerCurve = .continuous
        trayThumb.layer?.masksToBounds = true
        trayThumb.layer?.borderWidth = 1
        trayThumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        trayThumb.layer?.contentsGravity = .resizeAspectFill
        trayView.addSubview(trayThumb)

        trayWell.wantsLayer = true
        trayWell.layer?.cornerRadius = 16
        trayWell.layer?.cornerCurve = .continuous
        trayWell.layer?.masksToBounds = false
        trayWellIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        trayWell.addSubview(trayWellIcon)
        trayView.addSubview(trayWell)

        trayTitle.font = roundedFont(13, .bold)
        trayTitle.textColor = NSColor(white: 0.95, alpha: 1)
        trayTitle.lineBreakMode = .byTruncatingMiddle
        trayView.addSubview(trayTitle)

        traySub.font = roundedFont(11, .regular)
        traySub.textColor = NSColor(white: 0.55, alpha: 1)
        traySub.lineBreakMode = .byTruncatingTail
        trayView.addSubview(traySub)

        ringView.wantsLayer = true
        for layer in [ringTrack, ringArc] {
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 10,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            layer.path = path
            layer.fillColor = NSColor.clear.cgColor
            layer.lineWidth = 2.5
            layer.lineCap = .round
            ringView.layer?.addSublayer(layer)
        }
        ringTrack.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        ringNumeral.font = roundedFont(9, .semibold)
        ringNumeral.alignment = .center
        ringNumeral.frame = NSRect(x: 0, y: 5, width: 24, height: 12)
        ringNumeral.isHidden = true
        ringView.addSubview(ringNumeral)
        trayView.addSubview(ringView)

        sensorView.registerForDraggedTypes([.fileURL])
        sensorView.onEnter = { [weak self] in self?.hoverPeek() }
        sensorView.onExit = { [weak self] in self?.hoverEnd() }
        sensorView.onDragEnter = { [weak self] in
            guard let self, self.beginTransient(.prompt) else { return }
            self.show(.tray(image: nil, symbol: "plus.circle.fill", tint: Palette.ice,
                            title: "Drop to hold",
                            subtitle: "Release, then fist and open at another Mac",
                            deadline: nil, total: 0))
            self.scheduleSettle(after: IslandClass.prompt.dwell)
        }
        sensorView.onDrop = { [weak self] url in
            // A completed drop never sends draggingExited; clear the prompt ourselves.
            self?.scheduleSettle(after: 0.4)
            self?.onDropFile(url)
        }

        reanchor()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reanchor()
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.expanded, self.persistentFace == nil, self.collapseWork == nil else { return }
            self.hovering = false
            self.transientRank = 0
            self.transientUntil = .distantPast
            self.collapse()
        }
    }

    // MARK: Anchoring

    private func reanchor() {
        let notchScreen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notchScreen ?? NSScreen.main else {
            window.orderOut(nil)
            return
        }
        hasNotch = notchScreen != nil
        if hasNotch {
            let sides = (screen.auxiliaryTopLeftArea?.width ?? 0) + (screen.auxiliaryTopRightArea?.width ?? 0)
            notchWidth = max(screen.frame.width - sides, 120)
            notchHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 200
            notchHeight = 30
        }
        slabTop = canvasHeight - (hasNotch ? 0 : 8)

        let frame = NSRect(x: screen.frame.midX - canvasWidth / 2,
                           y: screen.frame.maxY - canvasHeight,
                           width: canvasWidth, height: canvasHeight)
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        for layer in pathLayers { layer.frame = canvas.bounds }
        hairline.frame = canvas.bounds
        hairlineMask.frame = canvas.bounds

        if hasNotch {
            let notchFrame = NSRect(x: screen.frame.midX - notchWidth / 2,
                                    y: screen.frame.maxY - notchHeight,
                                    width: notchWidth, height: notchHeight)
            if sensorWindow == nil {
                let w = NSWindow(contentRect: notchFrame, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.ignoresMouseEvents = false
                w.isReleasedWhenClosed = false
                w.level = .statusBar
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                w.contentView = sensorView
                sensorWindow = w
            }
            sensorWindow?.setFrame(notchFrame, display: true)
            sensorWindow?.orderFront(nil)
        } else {
            sensorWindow?.orderOut(nil)
        }

        if !expanded {
            setPaths(collapsedPath())
        } else if let face = persistentFace {
            show(face)
        } else {
            // A transient was up when the screens changed; its geometry is stale.
            collapseWork?.cancel()
            transientRank = 0
            transientUntil = .distantPast
            collapse()
        }
        layoutBeads()
    }

    // MARK: Silhouette

    /// Radius scales with height: 12pt compact, 18pt tray.
    private func bottomRadius(forHeight h: CGFloat) -> CGFloat {
        h > notchHeight + 8 ? 20 : 12
    }

    private func slabPath(centerX: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
        let minX = centerX - width / 2
        let maxX = centerX + width / 2
        let topY = slabTop
        let bottomY = slabTop - height
        let tr = min(topFlare, width / 4, height / 2)
        let br = min(bottomRadius(forHeight: height), width / 4 - tr, height / 2)

        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX, y: topY))
        p.addQuadCurve(to: CGPoint(x: minX + tr, y: topY - tr),
                       control: CGPoint(x: minX + tr, y: topY))
        p.addLine(to: CGPoint(x: minX + tr, y: bottomY + br))
        p.addQuadCurve(to: CGPoint(x: minX + tr + br, y: bottomY),
                       control: CGPoint(x: minX + tr, y: bottomY))
        p.addLine(to: CGPoint(x: maxX - tr - br, y: bottomY))
        p.addQuadCurve(to: CGPoint(x: maxX - tr, y: bottomY + br),
                       control: CGPoint(x: maxX - tr, y: bottomY))
        p.addLine(to: CGPoint(x: maxX - tr, y: topY - tr))
        p.addQuadCurve(to: CGPoint(x: maxX, y: topY),
                       control: CGPoint(x: maxX - tr, y: topY))
        p.closeSubpath()
        return p
    }

    private func collapsedPath() -> CGPath {
        slabPath(centerX: canvasWidth / 2, width: notchWidth, height: max(notchHeight, 0.5))
    }

    private func setPaths(_ path: CGPath) {
        for layer in pathLayers { layer.path = path }
    }

    private func setSlabVisible(_ visible: Bool) {
        let opacity: Float = visible ? 1 : 0
        for layer in [deepShadow, contactShadow, slab, hairline] {
            layer.opacity = opacity
        }
    }

    private func morph(to path: CGPath, spring: Bool) {
        for layer in pathLayers {
            let from = layer.presentation()?.path ?? layer.path
            let anim: CAAnimation
            if spring {
                let sa = CASpringAnimation(keyPath: "path")
                sa.fromValue = from
                sa.toValue = path
                sa.mass = 1
                sa.stiffness = 270
                sa.damping = 26
                sa.duration = sa.settlingDuration
                anim = sa
            } else {
                let ba = CABasicAnimation(keyPath: "path")
                ba.fromValue = from
                ba.toValue = path
                ba.duration = 0.22
                ba.timingFunction = CAMediaTimingFunction(name: .easeIn)
                anim = ba
            }
            layer.path = path
            layer.add(anim, forKey: "morph")
        }
    }

    // MARK: Public API

    /// Quick event in the wings. Status by default; prompts pulse their glyph.
    func compact(_ symbol: String?, _ tint: NSColor, _ word: String,
                 kind: IslandClass = .status, pulsing: Bool = false, seconds: TimeInterval? = nil) {
        let dwell = seconds ?? kind.dwell
        guard beginTransient(kind, for: dwell) else { return }
        show(.compact(symbol: symbol, tint: tint, word: word, pulsing: pulsing))
        scheduleSettle(after: dwell)
    }

    /// Standing hold or rich moment below the notch. Always trayWidth wide.
    func tray(image: NSImage?, symbol: String?, tint: NSColor, title: String, subtitle: String,
              deadline: Date?, total: TimeInterval, persist: Bool,
              kind: IslandClass = .outcome, seconds: TimeInterval = 4.5) {
        let face = Face.tray(image: image, symbol: symbol, tint: tint,
                             title: title, subtitle: subtitle, deadline: deadline, total: total)
        if persist {
            persistentFace = face
            if Date() >= transientUntil {
                collapseWork?.cancel()
                show(face)
            } else {
                // A transient is dwelling; let it finish, then settle into this tray.
                scheduleSettle(after: max(transientUntil.timeIntervalSinceNow, 0.05))
            }
        } else {
            guard beginTransient(kind, for: seconds) else { return }
            show(face)
            scheduleSettle(after: seconds)
        }
    }

    func clearPersist() {
        persistentFace = nil
        // Respect a dwelling transient; settle() collapses after it.
        guard Date() >= transientUntil else { return }
        collapseWork?.cancel()
        collapse()
    }

    /// A live transfer: the tray ring becomes a progress ring. Persists until
    /// endTransfer() or clearPersist().
    func transferTray(image: NSImage?, symbol: String?, tint: NSColor,
                      title: String, subtitle: String, progress: Progress) {
        let face = Face.progressTray(image: image, symbol: symbol, tint: tint,
                                     title: title, subtitle: subtitle, progress: progress)
        persistentFace = face
        collapseWork?.cancel()
        show(face)
    }

    /// The transfer ended; drop the standing face without collapsing, so an
    /// outcome pulse can take over cleanly.
    func endTransfer() {
        progressObservation?.invalidate()
        progressObservation = nil
        persistentFace = nil
    }

    func setPresence(_ connected: Int) {
        connectedCount = connected
        layoutBeads()
    }


    // MARK: Interrupt order

    @discardableResult
    private func beginTransient(_ kind: IslandClass, for seconds: TimeInterval? = nil) -> Bool {
        let now = Date()
        if now < transientUntil && kind.rawValue < transientRank { return false }
        transientRank = kind.rawValue
        transientUntil = now.addingTimeInterval(seconds ?? kind.dwell)
        collapseWork?.cancel()
        return true
    }

    private func scheduleSettle(after seconds: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func settle() {
        collapseWork = nil
        transientRank = 0
        transientUntil = .distantPast
        if hovering {
            hoverPeek()
        } else if let face = persistentFace {
            show(face)
        } else {
            collapse()
        }
    }

    // MARK: Hover

    private func hoverPeek() {
        hovering = true
        guard persistentFace == nil, Date() >= transientUntil else { return }
        collapseWork?.cancel()
        let status = statusProvider()
        show(.tray(image: nil, symbol: "hand.raised.fill", tint: Palette.ice,
                   title: status.title, subtitle: status.subtitle, deadline: nil, total: 0))
    }

    private func hoverEnd() {
        hovering = false
        // Never truncate a dwelling banner; its own settle is already scheduled.
        guard Date() >= transientUntil else { return }
        scheduleSettle(after: 0.3)
    }

    // MARK: Peer beads

    private func layoutBeads() {
        let target = hasNotch && !expanded ? min(connectedCount, 7) : 0
        while beads.count < target {
            let bead = CALayer()
            bead.bounds = CGRect(x: 0, y: 0, width: 3.5, height: 3.5)
            bead.cornerRadius = 1.75
            bead.backgroundColor = Palette.ice.cgColor
            bead.shadowColor = Palette.ice.cgColor
            bead.shadowRadius = 3
            bead.shadowOpacity = 0.8
            bead.shadowOffset = .zero
            beadRow.addSublayer(bead)
            beads.append(bead)
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0
            pop.toValue = 1
            pop.damping = 12
            pop.stiffness = 380
            pop.duration = pop.settlingDuration
            bead.add(pop, forKey: "join")
        }
        while beads.count > target {
            let bead = beads.removeLast()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.3
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            bead.add(fade, forKey: "leave")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { bead.removeFromSuperlayer() }
        }
        let spacing: CGFloat = 7
        let totalW = CGFloat(max(beads.count - 1, 0)) * spacing
        for (i, bead) in beads.enumerated() {
            bead.position = CGPoint(x: canvasWidth / 2 - totalW / 2 + CGFloat(i) * spacing,
                                    y: slabTop - notchHeight - 5)
        }
    }

    // MARK: Faces

    private func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func materialize() {
        setSlabVisible(true)
        expanded = true
        layoutBeads()
    }

    private func show(_ face: Face) {
        switch face {
        case let .compact(symbol, tint, word, pulsing):
            showCompact(symbol: symbol, tint: tint, word: word, pulsing: pulsing)
        case let .tray(image, symbol, tint, title, subtitle, deadline, total):
            showTray(image: image, symbol: symbol, tint: tint, title: title,
                     subtitle: subtitle, deadline: deadline, total: total)
        case let .progressTray(image, symbol, tint, title, subtitle, progress):
            showTray(image: image, symbol: symbol, tint: tint, title: title,
                     subtitle: subtitle, deadline: nil, total: 0, progress: progress)
        }
    }

    private func showCompact(symbol: String?, tint: NSColor, word: String, pulsing: Bool) {
        materialize()
        stopRingTimer()
        trayView.alphaValue = 0

        let h = max(notchHeight, 26)
        let wordW = word.isEmpty ? 0 : width(of: word, font: wingLabel.font ?? NSFont.systemFont(ofSize: 11))
        let leftWing: CGFloat = symbol != nil ? 16 + 18 + 14 : 14
        let rightWing: CGFloat = word.isEmpty ? leftWing : 16 + wordW + 18
        let w = notchWidth + leftWing + rightWing
        let centerX = canvasWidth / 2 + (rightWing - leftWing) / 2

        wingView.frame = NSRect(x: centerX - w / 2, y: slabTop - h, width: w, height: h)
        wingIcon.isHidden = symbol == nil
        wingIcon.layer?.removeAnimation(forKey: "promptPulse")
        if let symbol {
            wingIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            wingIcon.contentTintColor = tint
            wingIcon.frame = NSRect(x: 16, y: (h - 18) / 2, width: 18, height: 18)
            if pulsing {
                wingIcon.wantsLayer = true
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.6
                pulse.toValue = 1.0
                pulse.duration = 1.2
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wingIcon.layer?.add(pulse, forKey: "promptPulse")
            }
        }
        wingLabel.isHidden = word.isEmpty
        wingLabel.stringValue = word
        wingLabel.textColor = tint
        wingLabel.frame = NSRect(x: w - wordW - 18, y: (h - 14) / 2, width: wordW, height: 14)

        morph(to: slabPath(centerX: centerX, width: w, height: h), spring: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wingView.animator().alphaValue = 1
        }
    }

    private func showTray(image: NSImage?, symbol: String?, tint: NSColor, title: String,
                          subtitle: String, deadline: Date?, total: TimeInterval,
                          progress: Progress? = nil) {
        materialize()
        wingView.alphaValue = 0

        let hasRing = deadline != nil || progress != nil
        let w = trayWidth
        let h = notchHeight + trayBand

        trayView.frame = NSRect(x: (canvasWidth - w) / 2, y: slabTop - h, width: w, height: trayBand)
        var x: CGFloat = 28
        trayThumb.isHidden = image == nil
        trayWell.isHidden = !(image == nil && symbol != nil)
        if let image {
            trayThumb.layer?.contents = image
            trayThumb.frame = NSRect(x: x, y: (trayBand - 35) / 2, width: 56, height: 35)
            x += 56 + 18
        } else if let symbol {
            trayWell.frame = NSRect(x: x, y: (trayBand - 32) / 2, width: 32, height: 32)
            trayWellIcon.frame = trayWell.bounds
            trayWellIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            trayWellIcon.contentTintColor = tint
            trayWell.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
            trayWell.layer?.shadowColor = tint.cgColor
            trayWell.layer?.shadowRadius = 8
            trayWell.layer?.shadowOpacity = 0.5
            trayWell.layer?.shadowOffset = .zero
            x += 32 + 18
        }
        let ringSpace: CGFloat = hasRing ? 24 + 24 : 0
        let textWidth = w - x - 28 - ringSpace
        trayTitle.stringValue = title
        trayTitle.frame = NSRect(x: x, y: trayBand / 2 + 5, width: textWidth, height: 17)
        traySub.stringValue = subtitle
        traySub.frame = NSRect(x: x, y: trayBand / 2 - 20, width: textWidth, height: 14)

        ringView.isHidden = !hasRing
        stopRingTimer()
        if let progress {
            ringView.frame = NSRect(x: w - 24 - 24, y: (trayBand - 24) / 2, width: 24, height: 24)
            ringArc.strokeColor = tint.cgColor
            ringArc.removeAllAnimations()
            ringArc.strokeEnd = CGFloat(progress.fractionCompleted)
            ringNumeral.isHidden = false
            ringNumeral.textColor = tint
            progressObservation = progress.observe(\.fractionCompleted, options: [.initial]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.ringArc.strokeEnd = CGFloat(p.fractionCompleted)
                    self.ringNumeral.stringValue = "\(Int(p.fractionCompleted * 100))"
                }
            }
        } else if let deadline {
            ringView.frame = NSRect(x: w - 24 - 24, y: (trayBand - 24) / 2, width: 24, height: 24)
            ringTint = tint
            ringDeadline = deadline
            ringArc.strokeColor = tint.cgColor
            ringArc.removeAllAnimations()
            let remaining = max(deadline.timeIntervalSinceNow, 0.1)
            let fraction = total > 0 ? min(remaining / total, 1) : 1
            let drain = CABasicAnimation(keyPath: "strokeEnd")
            drain.fromValue = fraction
            drain.toValue = 0
            drain.duration = remaining
            drain.fillMode = .forwards
            drain.isRemovedOnCompletion = false
            ringArc.strokeEnd = 0
            ringArc.add(drain, forKey: "drain")
            ringNumeral.isHidden = true
            ringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.tickRing()
            }
        }

        morph(to: slabPath(centerX: canvasWidth / 2, width: w, height: h), spring: true)
        if let layer = (image != nil ? trayThumb.layer : trayWell.layer) {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.5
            spring.toValue = 1.0
            spring.damping = 13
            spring.stiffness = 420
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "pop")
        }
        let rise = trayView.frame.origin
        trayView.setFrameOrigin(NSPoint(x: rise.x, y: rise.y - 6))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            trayView.animator().alphaValue = 1
            trayView.animator().setFrameOrigin(rise)
        }
    }

    /// Urgency stages: state tint, then amber under 15s, coral plus a numeral
    /// under 10s.
    private func tickRing() {
        guard let deadline = ringDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            stopRingTimer()
            return
        }
        let color: NSColor
        if remaining <= 10 {
            color = Palette.coral
            ringNumeral.isHidden = false
            ringNumeral.stringValue = "\(Int(remaining.rounded(.up)))"
            ringNumeral.textColor = Palette.coral
        } else if remaining <= 15 {
            color = Palette.amber
            ringNumeral.isHidden = true
        } else {
            color = ringTint
            ringNumeral.isHidden = true
        }
        ringArc.strokeColor = color.cgColor
    }

    private func stopRingTimer() {
        ringTimer?.invalidate()
        ringTimer = nil
        ringDeadline = nil
        ringNumeral.isHidden = true
        progressObservation?.invalidate()
        progressObservation = nil
    }

    // MARK: Collapse

    /// Overlapped leave: content fades while the slab eases home. The end
    /// silhouette equals the notch, so there is nothing left to dissolve.
    private func collapse() {
        expanded = false
        stopRingTimer()
        morph(to: collapsedPath(), spring: false)
        NSAnimationContext.runAnimationGroup({ [weak self] ctx in
            ctx.duration = 0.16
            self?.wingView.animator().alphaValue = 0
            self?.trayView.animator().alphaValue = 0
        }, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, !self.expanded else { return }
            self.setSlabVisible(false)
            self.layoutBeads()
        }
    }
}


