import AppKit
import AVFoundation

/// First-run welcome: what Slingshot is, the four permissions as cards with
/// live status, the gesture line, one Done. Obsidian look, generous air.
final class OnboardingWindow: NSObject {
    static let shared = OnboardingWindow()

    private var window: NSWindow?
    private var statusTimer: Timer?
    private var onDone: () -> Void = {}

    private final class PermissionRow {
        let card = NSView()
        let button = NSButton()
        let grantedBadge = NSTextField(labelWithString: "Granted")
        var isGranted: () -> Bool = { false }
    }
    private var rows: [PermissionRow] = []

    func showIfNeeded(completion: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: "onboarded") else {
            completion()
            return
        }
        onDone = completion
        show()
    }

    /// Also reachable any time from the menu bar.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        present()
    }

    private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    private func present() {
        let width: CGFloat = 520
        let height: CGFloat = 610
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        w.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.autoresizingMask = [.width, .height]
        let margin: CGFloat = 44

        // Header
        let title = NSTextField(labelWithString: "Slingshot")
        title.font = roundedFont(30, .bold)
        title.textColor = .white
        title.frame = NSRect(x: margin, y: height - 96, width: 300, height: 40)
        content.addSubview(title)

        let sub = NSTextField(wrappingLabelWithString: "Grab your screen with a fist. Snap to wake the camera. Files cross the room by hand.")
        sub.font = roundedFont(13, .regular)
        sub.textColor = NSColor(white: 0.58, alpha: 1)
        sub.frame = NSRect(x: margin, y: height - 148, width: width - margin * 2, height: 40)
        content.addSubview(sub)

        // Permission cards
        struct Spec {
            let symbol: String
            let tint: NSColor
            let name: String
            let detail: String
            let action: Selector
            let buttonTitle: String
            let granted: () -> Bool
        }
        let specs: [Spec] = [
            Spec(symbol: "camera.fill", tint: NotchIsland.Palette.ice, name: "Camera",
                 detail: "Reads your hand gestures. Frames never leave the Mac.",
                 action: #selector(grantCamera), buttonTitle: "Grant",
                 granted: { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }),
            Spec(symbol: "mic.fill", tint: NotchIsland.Palette.amber, name: "Microphone",
                 detail: "Hears the finger snap that wakes the camera. On-device only.",
                 action: #selector(grantMic), buttonTitle: "Grant",
                 granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }),
            Spec(symbol: "rectangle.inset.filled.badge.record", tint: NotchIsland.Palette.coral, name: "Screen Recording",
                 detail: "Lets the grab gesture take the screenshot. Relaunch after granting.",
                 action: #selector(grantScreen), buttonTitle: "Open",
                 granted: { CGPreflightScreenCaptureAccess() }),
            Spec(symbol: "wifi", tint: NotchIsland.Palette.mint, name: "Local Network",
                 detail: "Finds nearby Macs. macOS asks by itself on first connection.",
                 action: #selector(networkInfo), buttonTitle: "Info",
                 granted: { false }),
        ]

        let cardHeight: CGFloat = 78
        let cardGap: CGFloat = 14
        var y = height - 186 - cardHeight
        rows = []
        for spec in specs {
            let row = PermissionRow()
            let card = row.card
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
            card.layer?.cornerRadius = 14
            card.layer?.cornerCurve = .continuous
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
            card.frame = NSRect(x: margin, y: y, width: width - margin * 2, height: cardHeight)
            content.addSubview(card)

            let well = NSView(frame: NSRect(x: 18, y: (cardHeight - 34) / 2, width: 34, height: 34))
            well.wantsLayer = true
            well.layer?.cornerRadius = 17
            well.layer?.backgroundColor = spec.tint.withAlphaComponent(0.15).cgColor
            let icon = NSImageView(frame: well.bounds)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            icon.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil)
            icon.contentTintColor = spec.tint
            well.addSubview(icon)
            card.addSubview(well)

            let name = NSTextField(labelWithString: spec.name)
            name.font = roundedFont(13, .semibold)
            name.textColor = .white
            name.frame = NSRect(x: 66, y: cardHeight - 34, width: 250, height: 18)
            card.addSubview(name)

            let detail = NSTextField(wrappingLabelWithString: spec.detail)
            detail.font = roundedFont(11, .regular)
            detail.textColor = NSColor(white: 0.52, alpha: 1)
            detail.frame = NSRect(x: 66, y: 12, width: 264, height: 30)
            card.addSubview(detail)

            let button = row.button
            button.title = spec.buttonTitle
            button.target = self
            button.action = spec.action
            button.bezelStyle = .rounded
            button.font = roundedFont(12, .medium)
            button.frame = NSRect(x: card.frame.width - 96, y: (cardHeight - 28) / 2, width: 78, height: 28)
            card.addSubview(button)

            let badge = row.grantedBadge
            badge.font = roundedFont(12, .semibold)
            badge.textColor = NotchIsland.Palette.mint
            badge.alignment = .right
            badge.frame = NSRect(x: card.frame.width - 116, y: (cardHeight - 16) / 2, width: 98, height: 16)
            badge.isHidden = true
            card.addSubview(badge)

            row.isGranted = spec.granted
            rows.append(row)
            y -= cardHeight + cardGap
        }

        // Footer: hairline, gesture line, Done. No overlaps, ever.
        let hairline = NSView(frame: NSRect(x: margin, y: 92, width: width - margin * 2, height: 1))
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        content.addSubview(hairline)

        let cheat = NSTextField(wrappingLabelWithString: "Palm 2 seconds to arm. Fist 1 second to grab. Fist, then open hand at another Mac to catch.")
        cheat.font = roundedFont(11, .regular)
        cheat.textColor = NSColor(white: 0.45, alpha: 1)
        cheat.frame = NSRect(x: margin, y: 30, width: width - margin * 2 - 130, height: 44)
        content.addSubview(cheat)

        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.keyEquivalent = "\r"
        done.font = roundedFont(13, .semibold)
        done.frame = NSRect(x: width - margin - 96, y: 34, width: 96, height: 34)
        content.addSubview(done)

        w.contentView = content
        window = w
        refreshStatuses()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Buttons become a mint Granted badge the moment permission lands.
    private func refreshStatuses() {
        for row in rows where row.isGranted() {
            row.button.isHidden = true
            row.grantedBadge.isHidden = false
            row.grantedBadge.stringValue = "Granted"
        }
    }

    @objc private func grantCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
    }

    @objc private func grantMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    @objc private func grantScreen() {
        CGRequestScreenCaptureAccess()
    }

    @objc private func networkInfo() {
        let alert = NSAlert()
        alert.messageText = "Local Network"
        alert.informativeText = "macOS shows its own prompt the first time Slingshot looks for nearby Macs. Approve it when it appears."
        alert.runModal()
    }

    @objc private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        statusTimer?.invalidate()
        statusTimer = nil
        window?.orderOut(nil)
        window = nil
        rows = []
        onDone()
        onDone = {}
    }
}
