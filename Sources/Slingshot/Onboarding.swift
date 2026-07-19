import AppKit
import AVFoundation

/// First-run welcome, implementing the design specification: fixed 560x748,
/// reserved bands so no state ever collides, a miniature island as the hero,
/// permission cards whose glyph well is the status lamp, gesture storyboard
/// panels with ambient teaching, and a Done that brightens when the work is
/// finished but never holds anyone hostage.
final class OnboardingWindow: NSObject {
    static let shared = OnboardingWindow()

    private enum Spec {
        static let width: CGFloat = 560
        static let height: CGFloat = 748
        static let margin: CGFloat = 28
        static let windowFill = NSColor(calibratedRed: 0.051, green: 0.051, blue: 0.059, alpha: 1)
        static let cardFill = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
        static let panelFill = NSColor(calibratedRed: 0.063, green: 0.063, blue: 0.075, alpha: 1)
        static let ice = NSColor(calibratedRed: 0.349, green: 0.851, blue: 1.0, alpha: 1)
        static let amber = NSColor(calibratedRed: 1.0, green: 0.722, blue: 0.2, alpha: 1)
        static let mint = NSColor(calibratedRed: 0.302, green: 0.902, blue: 0.549, alpha: 1)
        static let coral = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 1)
        static let ash = NSColor(calibratedRed: 0.78, green: 0.78, blue: 0.78, alpha: 1)
    }

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var idleTimer: Timer?
    private var onDone: () -> Void = {}
    private var cards: [PermissionCard] = []
    private var statusLine: NSTextField?
    private var doneButton: FlatButton?
    private var doneSolid = false
    private var cardAnimating = false
    private var panelWells: [[NSView]] = []
    private var idleStep = 0

    // MARK: Helpers

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    /// Capsule button drawn with layers; AppKit bezels do not belong here.
    private final class FlatButton: NSButton {
        var fillColor = NSColor.white.withAlphaComponent(0.08) { didSet { restyle() } }
        var borderColor = NSColor.white.withAlphaComponent(0.10) { didSet { restyle() } }
        var labelColor = NSColor.white { didSet { restyle() } }

        convenience init(label: String, size: NSSize, fontSize: CGFloat = 12) {
            self.init(frame: NSRect(origin: .zero, size: size))
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = size.height / 2
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            font = OnboardingWindow.rounded(fontSize, .semibold)
            title = label
            restyle()
        }

        func restyle() {
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderColor = borderColor.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: labelColor,
            ])
        }
    }

    private static func well(diameter: CGFloat, tint: NSColor, symbol: String, glyphSize: CGFloat,
                             fillAlpha: CGFloat = 0.12) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        v.wantsLayer = true
        v.layer?.cornerRadius = diameter / 2
        v.layer?.backgroundColor = tint.withAlphaComponent(fillAlpha).cgColor
        let icon = NSImageView(frame: v.bounds)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.autoresizingMask = [.width, .height]
        v.addSubview(icon)
        return v
    }

    // MARK: Permission cards

    private final class PermissionCard {
        enum State { case normal, granted, relaunchPending, denied }
        let card = NSView()
        let well = NSView()
        let wellIcon = NSImageView()
        let nameLabel = NSTextField(labelWithString: "")
        let detailLabel = NSTextField(labelWithString: "")
        var pill: FlatButton?
        let badgeIcon = NSImageView()
        let badgeLabel = NSTextField(labelWithString: "")
        var tint = NSColor.white
        var symbol = ""
        var confirmation = ""
        var state = State.normal
        var check: () -> State = { .normal }
    }

    // MARK: Presentation

    func showIfNeeded(completion: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: "onboarded") else {
            completion()
            return
        }
        onDone = completion
        show()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        present()
    }

    private func present() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Spec.width, height: Spec.height),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = Spec.windowFill
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Spec.width, height: Spec.height))
        content.wantsLayer = true

        buildHero(in: content)
        buildCards(in: content)
        buildGesturePanels(in: content)
        buildFooter(in: content)

        w.contentView = content
        window = w

        runEntrance(content)
        refreshPermissions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tickIdle()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Hero (band y 0-176 from the top)

    private var heroSlab = CAShapeLayer()
    private var heroWells: [NSView] = []
    private var heroName: NSTextField?
    private var heroSub: NSTextField?

    private func slabPath(width: CGFloat, height: CGFloat) -> CGPath {
        let minX = (Spec.width - width) / 2
        let maxX = minX + width
        let topY = Spec.height
        let bottomY = Spec.height - height
        let tr: CGFloat = min(8, height / 2)
        let br: CGFloat = min(14, height / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX, y: topY))
        p.addQuadCurve(to: CGPoint(x: minX + tr, y: topY - tr), control: CGPoint(x: minX + tr, y: topY))
        p.addLine(to: CGPoint(x: minX + tr, y: bottomY + br))
        p.addQuadCurve(to: CGPoint(x: minX + tr + br, y: bottomY), control: CGPoint(x: minX + tr, y: bottomY))
        p.addLine(to: CGPoint(x: maxX - tr - br, y: bottomY))
        p.addQuadCurve(to: CGPoint(x: maxX - tr, y: bottomY + br), control: CGPoint(x: maxX - tr, y: bottomY))
        p.addLine(to: CGPoint(x: maxX - tr, y: topY - tr))
        p.addQuadCurve(to: CGPoint(x: maxX, y: topY), control: CGPoint(x: maxX - tr, y: topY))
        p.closeSubpath()
        return p
    }

    private func buildHero(in content: NSView) {
        // Radial ice wash behind the hero only
        let wash = CAGradientLayer()
        wash.type = .radial
        wash.colors = [Spec.ice.withAlphaComponent(0.05).cgColor, NSColor.clear.cgColor]
        wash.startPoint = CGPoint(x: 0.5, y: 1.0)
        wash.endPoint = CGPoint(x: 1.0, y: 0.35)
        wash.frame = NSRect(x: Spec.width / 2 - 260, y: Spec.height - 200, width: 520, height: 200)
        content.layer?.addSublayer(wash)

        // The mini island, born from the same path code as the notch UI
        heroSlab = CAShapeLayer()
        heroSlab.path = slabPath(width: 120, height: 0.5)
        heroSlab.fillColor = NSColor.black.cgColor
        heroSlab.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        heroSlab.lineWidth = 1
        heroSlab.shadowColor = NSColor.black.cgColor
        heroSlab.shadowOpacity = 0.55
        heroSlab.shadowRadius = 18
        heroSlab.shadowOffset = CGSize(width: 0, height: -6)
        content.layer?.addSublayer(heroSlab)

        // Wells inside the slab: hand, motion, other Mac
        let handWell = Self.well(diameter: 26, tint: Spec.ice, symbol: "hand.raised.fingers.spread", glyphSize: 13)
        let arrow = NSImageView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        arrow.contentTintColor = Spec.ash.withAlphaComponent(0.4)
        let macWell = Self.well(diameter: 26, tint: Spec.mint, symbol: "macbook", glyphSize: 13)

        let rowWidth: CGFloat = 26 + 12 + 18 + 12 + 26
        var x = (Spec.width - rowWidth) / 2
        for view in [handWell, arrow, macWell] {
            let h = view.frame.height
            view.setFrameOrigin(NSPoint(x: x, y: Spec.height - 44 + (44 - h) / 2))
            view.alphaValue = 0
            content.addSubview(view)
            x += view.frame.width + 12
        }
        heroWells = [handWell, arrow, macWell]

        // Ember on the slab's bottom edge, the same heartbeat as the notch
        let ember = CALayer()
        ember.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        ember.cornerRadius = 2
        ember.backgroundColor = Spec.ice.cgColor
        ember.shadowColor = Spec.ice.cgColor
        ember.shadowRadius = 4
        ember.shadowOpacity = 0.9
        ember.shadowOffset = .zero
        ember.position = CGPoint(x: Spec.width / 2, y: Spec.height - 44)
        ember.opacity = 0
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.30
        breathe.toValue = 0.65
        breathe.duration = 2.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        content.layer?.addSublayer(ember)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ember.opacity = 0.45
            ember.add(breathe, forKey: "breathe")
        }

        let name = NSTextField(labelWithString: "Slingshot")
        name.font = Self.rounded(26, .bold)
        name.textColor = .white
        name.alignment = .center
        name.frame = NSRect(x: 0, y: Spec.height - 100, width: Spec.width, height: 34)
        name.alphaValue = 0
        content.addSubview(name)
        heroName = name

        let sub = NSTextField(labelWithString: "Move files between Macs with your hands.")
        sub.font = Self.rounded(13, .medium)
        sub.textColor = Spec.ash.withAlphaComponent(0.6)
        sub.alignment = .center
        sub.frame = NSRect(x: 0, y: Spec.height - 126, width: Spec.width, height: 18)
        sub.alphaValue = 0
        content.addSubview(sub)
        heroSub = sub
    }

    // MARK: Cards (band y 176-472)

    private func buildCards(in content: NSView) {
        struct Def {
            let tint: NSColor
            let symbol: String
            let name: String
            let detail: String
            let confirmation: String
            let action: Selector
            let check: () -> PermissionCard.State
        }
        let defs: [Def] = [
            Def(tint: Spec.ice, symbol: "camera.fill", name: "Camera",
                detail: "Sees your gestures. Nothing is recorded.",
                confirmation: "Ready to see gestures.",
                action: #selector(grantCamera),
                check: {
                    switch AVCaptureDevice.authorizationStatus(for: .video) {
                    case .authorized: return .granted
                    case .denied, .restricted: return .denied
                    default: return .normal
                    }
                }),
            Def(tint: Spec.amber, symbol: "mic.fill", name: "Microphone",
                detail: "Hears the snap that wakes the camera.",
                confirmation: "Ready to hear the snap.",
                action: #selector(grantMic),
                check: {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized: return .granted
                    case .denied, .restricted: return .denied
                    default: return .normal
                    }
                }),
            Def(tint: Spec.coral, symbol: "rectangle.inset.filled.badge.record", name: "Screen Recording",
                detail: "Lets the grab gesture take the screenshot.",
                confirmation: "Ready to grab the screen.",
                action: #selector(grantScreen),
                check: {
                    guard CGPreflightScreenCaptureAccess() else { return .normal }
                    // Granted this session means a relaunch is still owed.
                    return UserDefaults.standard.bool(forKey: "screenGrantPending") ? .relaunchPending : .granted
                }),
            Def(tint: Spec.mint, symbol: "wifi", name: "Local Network",
                detail: "Finds nearby Macs. macOS asks by itself.",
                confirmation: "Watching for nearby Macs.",
                action: #selector(networkInfo),
                check: { .normal }),
        ]

        cards = []
        for (i, def) in defs.enumerated() {
            let c = PermissionCard()
            c.tint = def.tint
            c.symbol = def.symbol
            c.confirmation = def.confirmation
            c.check = def.check

            let top: CGFloat = 190 + CGFloat(i) * 74
            c.card.frame = NSRect(x: Spec.margin, y: Spec.height - top - 64, width: Spec.width - Spec.margin * 2, height: 64)
            c.card.wantsLayer = true
            c.card.layer?.backgroundColor = Spec.cardFill.cgColor
            c.card.layer?.cornerRadius = 12
            c.card.layer?.cornerCurve = .continuous
            c.card.layer?.borderWidth = 1
            c.card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
            c.card.alphaValue = 0
            content.addSubview(c.card)

            c.well.frame = NSRect(x: 16, y: 16, width: 32, height: 32)
            c.well.wantsLayer = true
            c.well.layer?.cornerRadius = 16
            c.well.layer?.backgroundColor = def.tint.withAlphaComponent(0.12).cgColor
            c.wellIcon.frame = c.well.bounds
            c.wellIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            c.wellIcon.image = NSImage(systemSymbolName: def.symbol, accessibilityDescription: nil)
            c.wellIcon.contentTintColor = def.tint
            c.well.addSubview(c.wellIcon)
            c.card.addSubview(c.well)

            c.nameLabel.stringValue = def.name
            c.nameLabel.font = Self.rounded(13, .semibold)
            c.nameLabel.textColor = .white
            c.nameLabel.frame = NSRect(x: 60, y: 33, width: 280, height: 18)
            c.card.addSubview(c.nameLabel)

            c.detailLabel.stringValue = def.detail
            c.detailLabel.font = Self.rounded(11, .regular)
            c.detailLabel.textColor = Spec.ash.withAlphaComponent(0.6)
            c.detailLabel.lineBreakMode = .byTruncatingTail
            c.detailLabel.frame = NSRect(x: 60, y: 14, width: 300, height: 15)
            c.card.addSubview(c.detailLabel)

            let isNetwork = def.name == "Local Network"
            let pill = FlatButton(label: isNetwork ? "Info" : "Grant", size: NSSize(width: 72, height: 28))
            pill.target = self
            pill.action = def.action
            pill.setFrameOrigin(NSPoint(x: c.card.frame.width - 72 - 16, y: 18))
            c.card.addSubview(pill)
            c.pill = pill

            c.badgeIcon.frame = NSRect(x: c.card.frame.width - 16 - 88, y: 24, width: 16, height: 16)
            c.badgeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            c.badgeIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            c.badgeIcon.contentTintColor = Spec.mint
            c.badgeIcon.isHidden = true
            c.card.addSubview(c.badgeIcon)

            c.badgeLabel.stringValue = "Granted"
            c.badgeLabel.font = Self.rounded(11, .semibold)
            c.badgeLabel.textColor = Spec.mint
            c.badgeLabel.frame = NSRect(x: c.card.frame.width - 16 - 66, y: 24, width: 66, height: 15)
            c.badgeLabel.isHidden = true
            c.card.addSubview(c.badgeLabel)

            cards.append(c)
        }
    }

    /// The Granted timeline: the well is the status lamp.
    private func land(_ c: PermissionCard) {
        guard c.state != .granted else { return }
        c.state = .granted
        cardAnimating = true

        if let pill = c.pill {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
                pill.animator().alphaValue = 0
                pill.animator().setFrameOrigin(NSPoint(x: pill.frame.origin.x, y: pill.frame.origin.y - 4))
            }, completionHandler: { pill.isHidden = true })
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            c.wellIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            c.wellIcon.contentTintColor = Spec.mint
            let fill = CABasicAnimation(keyPath: "backgroundColor")
            fill.fromValue = c.tint.withAlphaComponent(0.12).cgColor
            fill.toValue = Spec.mint.withAlphaComponent(0.18).cgColor
            fill.duration = 0.2
            fill.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            c.well.layer?.backgroundColor = Spec.mint.withAlphaComponent(0.18).cgColor
            c.well.layer?.add(fill, forKey: "lamp")

            let ring = CAShapeLayer()
            let d: CGFloat = 32
            ring.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = Spec.mint.cgColor
            ring.lineWidth = 1.5
            ring.position = CGPoint(x: c.well.frame.midX, y: c.well.frame.midY)
            ring.opacity = 0.6
            c.card.layer?.addSublayer(ring)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 52.0 / 32.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.6
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.45
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            c.badgeIcon.isHidden = false
            c.badgeLabel.isHidden = false
            for view in [c.badgeIcon, c.badgeLabel] as [NSView] {
                view.wantsLayer = true
                let spring = CASpringAnimation(keyPath: "transform.scale")
                spring.fromValue = 0.4
                spring.toValue = 1.0
                spring.stiffness = 520
                spring.damping = 24
                spring.mass = 1
                spring.duration = spring.settlingDuration
                view.layer?.add(spring, forKey: "pop")
            }
            let decay = CABasicAnimation(keyPath: "borderColor")
            decay.fromValue = Spec.mint.withAlphaComponent(0.30).cgColor
            decay.toValue = NSColor.white.withAlphaComponent(0.06).cgColor
            decay.duration = 0.6
            c.card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
            c.card.layer?.add(decay, forKey: "flash")

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                c.detailLabel.animator().alphaValue = 0
            } completionHandler: {
                c.detailLabel.stringValue = c.confirmation
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    c.detailLabel.animator().alphaValue = 1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self?.cardAnimating = false
            }
        }
    }

    private func applyRelaunchPending(_ c: PermissionCard) {
        guard c.state != .relaunchPending else { return }
        c.state = .relaunchPending
        c.well.layer?.backgroundColor = Spec.amber.withAlphaComponent(0.18).cgColor
        c.wellIcon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        c.wellIcon.contentTintColor = Spec.amber
        c.detailLabel.stringValue = "Relaunch Slingshot to finish."
        if let pill = c.pill {
            pill.isHidden = false
            pill.alphaValue = 1
            pill.title = "Relaunch"
            pill.setFrameSize(NSSize(width: 92, height: 28))
            pill.setFrameOrigin(NSPoint(x: c.card.frame.width - 92 - 16, y: 18))
            pill.fillColor = Spec.amber.withAlphaComponent(0.14)
            pill.borderColor = Spec.amber.withAlphaComponent(0.30)
            pill.labelColor = Spec.amber
            pill.action = #selector(relaunchApp)
        }
    }

    private func applyDenied(_ c: PermissionCard) {
        guard c.state != .denied else { return }
        c.state = .denied
        c.detailLabel.stringValue = "Allow it in System Settings, Privacy."
        if let pill = c.pill {
            pill.title = "Open Settings"
            pill.setFrameSize(NSSize(width: 110, height: 28))
            pill.setFrameOrigin(NSPoint(x: c.card.frame.width - 110 - 16, y: 18))
            pill.action = #selector(openPrivacySettings)
            pill.restyle()
        }
    }

    // MARK: Gesture panels (band y 472-648)

    private func buildGesturePanels(in content: NSView) {
        struct Step {
            let symbol: String
            let chip: String?
        }
        struct Panel {
            let title: String
            let tint: NSColor
            let steps: [Step]
            let caption: String
        }
        let panels = [
            Panel(title: "GRAB", tint: Spec.ice,
                  steps: [Step(symbol: "hand.raised.fingers.spread", chip: "2s"),
                          Step(symbol: "hand.raised.fill", chip: "1s"),
                          Step(symbol: "camera.viewfinder", chip: nil)],
                  caption: "Hold your palm up, then make a fist."),
            Panel(title: "CATCH", tint: Spec.mint,
                  steps: [Step(symbol: "hand.raised.fill", chip: "1s"),
                          Step(symbol: "hand.raised.fingers.spread", chip: nil),
                          Step(symbol: "checkmark", chip: nil)],
                  caption: "At the other Mac, fist then open your hand."),
        ]

        panelWells = []
        for (i, def) in panels.enumerated() {
            let x = Spec.margin + CGFloat(i) * (246 + 12)
            let panel = NSView(frame: NSRect(x: x, y: Spec.height - 488 - 144, width: 246, height: 144))
            panel.wantsLayer = true
            panel.layer?.backgroundColor = Spec.panelFill.cgColor
            panel.layer?.cornerRadius = 12
            panel.layer?.cornerCurve = .continuous
            panel.layer?.borderWidth = 1
            panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
            panel.alphaValue = 0
            panel.identifier = NSUserInterfaceItemIdentifier("gesturePanel")
            content.addSubview(panel)

            let header = NSTextField(labelWithString: def.title)
            header.attributedStringValue = NSAttributedString(string: def.title, attributes: [
                .font: Self.rounded(11, .bold), .foregroundColor: def.tint, .kern: 0.6,
            ])
            header.frame = NSRect(x: 16, y: 144 - 14 - 14, width: 120, height: 14)
            panel.addSubview(header)

            var rowWidth: CGFloat = 0
            for j in 0..<def.steps.count {
                rowWidth += 36
                if j < def.steps.count - 1 { rowWidth += 30 }
            }
            var sx = (246 - rowWidth) / 2
            var wells: [NSView] = []
            for (j, step) in def.steps.enumerated() {
                let well = Self.well(diameter: 36, tint: def.tint, symbol: step.symbol, glyphSize: 17)
                well.setFrameOrigin(NSPoint(x: sx, y: 144 - 62 - 18))
                panel.addSubview(well)
                wells.append(well)

                if let chip = step.chip {
                    let chipView = NSTextField(labelWithString: chip)
                    chipView.font = Self.rounded(9, .bold)
                    chipView.textColor = Spec.ash
                    chipView.alignment = .center
                    chipView.wantsLayer = true
                    chipView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                    chipView.layer?.cornerRadius = 8
                    chipView.frame = NSRect(x: sx + 6, y: 144 - 62 - 18 - 6 - 16, width: 24, height: 16)
                    panel.addSubview(chipView)
                }
                sx += 36
                if j < def.steps.count - 1 {
                    let chevron = NSImageView(frame: NSRect(x: sx + 10, y: 144 - 62 - 5, width: 10, height: 10))
                    chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                    chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                    chevron.contentTintColor = Spec.ash.withAlphaComponent(0.35)
                    panel.addSubview(chevron)
                    sx += 30
                }
            }
            panelWells.append(wells)

            let caption = NSTextField(labelWithString: def.caption)
            caption.font = Self.rounded(11, .regular)
            caption.textColor = Spec.ash.withAlphaComponent(0.6)
            caption.alignment = .center
            caption.frame = NSRect(x: 8, y: 12, width: 230, height: 15)
            panel.addSubview(caption)
        }
    }

    /// The window quietly performs the gestures: wells brighten in step order,
    /// panels offset by half a cycle. Pauses while a card lands its moment.
    private func tickIdle() {
        guard !cardAnimating else { return }
        idleStep += 1
        for (p, wells) in panelWells.enumerated() {
            let phase = (idleStep + (p == 1 ? 5 : 0)) % 10
            guard phase < wells.count else { continue }
            let well = wells[phase]
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 1.0
            spring.toValue = 1.08
            spring.stiffness = 380
            spring.damping = 24
            spring.duration = spring.settlingDuration
            spring.autoreverses = true
            well.layer?.add(spring, forKey: "breathe")
        }
    }

    // MARK: Footer (band y 648-748)

    private func buildFooter(in content: NSView) {
        let hairline = NSView(frame: NSRect(x: Spec.margin, y: Spec.height - 664, width: Spec.width - Spec.margin * 2, height: 1))
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        content.addSubview(hairline)

        let status = NSTextField(labelWithString: "0 of 4 granted")
        status.font = Self.rounded(11, .medium)
        status.textColor = Spec.ash.withAlphaComponent(0.6)
        status.frame = NSRect(x: Spec.margin, y: Spec.height - 706 - 8, width: 200, height: 16)
        content.addSubview(status)
        statusLine = status

        let done = FlatButton(label: "Done", size: NSSize(width: 120, height: 36), fontSize: 13)
        done.target = self
        done.action = #selector(finish)
        done.keyEquivalent = "\r"
        done.setFrameOrigin(NSPoint(x: Spec.width - Spec.margin - 120, y: Spec.height - 706 - 18))
        content.addSubview(done)
        doneButton = done
    }

    // MARK: State polling

    private func refreshPermissions() {
        var grantedCount = 0
        for c in cards {
            switch c.check() {
            case .granted:
                grantedCount += 1
                land(c)
            case .relaunchPending:
                applyRelaunchPending(c)
            case .denied:
                applyDenied(c)
            case .normal:
                break
            }
        }
        // Local Network cannot be queried; three grantable permissions is complete.
        statusLine?.stringValue = grantedCount >= 3 ? "You're set." : "\(grantedCount) of 4 granted"
        statusLine?.textColor = grantedCount >= 3 ? Spec.mint.withAlphaComponent(0.8) : Spec.ash.withAlphaComponent(0.6)

        if grantedCount >= 3 && !doneSolid, let done = doneButton {
            doneSolid = true
            done.fillColor = NSColor.white.withAlphaComponent(0.92)
            done.borderColor = .clear
            done.labelColor = .black
            let bump = CASpringAnimation(keyPath: "transform.scale")
            bump.fromValue = 1.0
            bump.toValue = 1.04
            bump.stiffness = 380
            bump.damping = 22
            bump.autoreverses = true
            bump.duration = bump.settlingDuration
            done.layer?.add(bump, forKey: "land")
        }
    }

    // MARK: Entrance

    private func runEntrance(_ content: NSView) {
        content.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let morph = CASpringAnimation(keyPath: "path")
            morph.fromValue = self.slabPath(width: 120, height: 0.5)
            morph.toValue = self.slabPath(width: 224, height: 44)
            morph.stiffness = 270
            morph.damping = 26
            morph.mass = 1
            morph.duration = morph.settlingDuration
            self.heroSlab.path = self.slabPath(width: 224, height: 44)
            self.heroSlab.add(morph, forKey: "born")
        }

        for (i, well) in heroWells.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.06) {
                well.alphaValue = 1
                well.wantsLayer = true
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.5
                pop.toValue = 1.0
                pop.stiffness = 520
                pop.damping = 24
                pop.duration = pop.settlingDuration
                well.layer?.add(pop, forKey: "pop")
            }
        }

        for (delay, view) in [(0.24, heroName), (0.30, heroSub)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let view else { return }
                let rest = view.frame.origin
                view.setFrameOrigin(NSPoint(x: rest.x, y: rest.y - 6))
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    view.animator().alphaValue = 1
                    view.animator().setFrameOrigin(rest)
                }
            }
        }

        for (i, c) in cards.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32 + Double(i) * 0.045) {
                let rest = c.card.frame.origin
                c.card.setFrameOrigin(NSPoint(x: rest.x, y: rest.y - 6))
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    c.card.animator().alphaValue = 1
                    c.card.animator().setFrameOrigin(rest)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let content = self.window?.contentView else { return }
            for panel in content.subviews where panel.identifier?.rawValue == "gesturePanel" {
                let rest = panel.frame.origin
                panel.setFrameOrigin(NSPoint(x: rest.x, y: rest.y - 6))
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    panel.animator().alphaValue = 1
                    panel.animator().setFrameOrigin(rest)
                }
            }
        }
    }

    // MARK: Actions

    @objc private func grantCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
    }

    @objc private func grantMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    @objc private func grantScreen() {
        if !CGPreflightScreenCaptureAccess() {
            UserDefaults.standard.set(true, forKey: "screenGrantPending")
            CGRequestScreenCaptureAccess()
        }
    }

    @objc private func relaunchApp() {
        UserDefaults.standard.removeObject(forKey: "screenGrantPending")
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func networkInfo() {
        let alert = NSAlert()
        alert.messageText = "Local Network"
        alert.informativeText = "macOS shows its own prompt the first time Slingshot looks for nearby Macs. Approve it when it appears."
        alert.runModal()
    }

    /// Exit: content first, then the window, then the island takes over.
    @objc private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        pollTimer?.invalidate()
        pollTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            w.contentView?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                w.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                w.orderOut(nil)
                w.alphaValue = 1
                self.window = nil
                self.cards = []
                self.panelWells = []
                self.doneSolid = false
                // The handoff is the last lesson.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                        wakeCamera("welcome done")
                    }
                }
                self.onDone()
                self.onDone = {}
            })
        })
    }
}
