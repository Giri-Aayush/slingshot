import AVFoundation
import AppKit
import CoreImage
import MultipeerConnectivity
import SoundAnalysis
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

// MARK: - Transfer modes and face identity

/// Normal: the hold carries the grabber's face print, and the receiving Mac only
/// completes the drop for a matching face. Best effort, not a security boundary:
/// the print is a Vision image-similarity embedding, not a face-recognition model.
/// Pro: anyone at any connected Mac can catch.
enum TransferMode: String { case normal, pro }

let modeLock = NSLock()
private var currentModeStorage: TransferMode = .normal
/// Set from the menu bar, read on the camera and grab queues.
var currentMode: TransferMode {
    get { modeLock.withLock { currentModeStorage } }
    set { modeLock.withLock { currentModeStorage = newValue } }
}

/// Revision 2 feature-print distances run about 0 (identical) to 2 (unrelated).
/// Every check logs its distance so this cutoff can be tuned from real data.
let faceMatchThreshold: Float = 0.55

/// Latest camera frame, shared safely across the camera, grab, and catch threads.
final class FrameStore {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var handAt = Date.distantPast
    func set(_ pb: CVPixelBuffer) { lock.withLock { buffer = pb } }
    func latest() -> CVPixelBuffer? { lock.withLock { buffer } }
    func clear() { lock.withLock { buffer = nil } }
    func markHand() { lock.withLock { handAt = Date() } }
    func lastHand() -> Date { lock.withLock { handAt } }
}
let frameStore = FrameStore()

/// Face feature-prints for "is this the same person who grabbed?".
/// Fresh Vision requests per call, so concurrent grab and catch paths share no state.
enum FaceID {
    static func faceprint(from pixelBuffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil,
              let faces = faceRequest.results, !faces.isEmpty else { return nil }
        let largest = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }!

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = ci.extent.width
        let h = ci.extent.height
        let bb = largest.boundingBox
        let raw = CGRect(x: bb.minX * w, y: bb.minY * h, width: bb.width * w, height: bb.height * h)
        let padded = raw.insetBy(dx: -raw.width * 0.15, dy: -raw.height * 0.15)
        let crop = padded.intersection(ci.extent)
        guard !crop.isNull, crop.width > 20, crop.height > 20,
              let cg = CIContext(options: nil).createCGImage(ci, from: crop) else { return nil }

        let fpRequest = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14.0, *) {
            // Pin the revision: the distance scale changes completely between revisions.
            fpRequest.revision = VNGenerateImageFeaturePrintRequestRevision2
        }
        let fpHandler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        guard (try? fpHandler.perform([fpRequest])) != nil else { return nil }
        return fpRequest.results?.first as? VNFeaturePrintObservation
    }

    static func encode(_ obs: VNFeaturePrintObservation) -> String? {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
        else { return nil }
        return data.base64EncodedString()
    }

    static func decode(_ s: String) -> VNFeaturePrintObservation? {
        guard let data = Data(base64Encoded: s) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Smaller is more similar. nil when the prints are incomparable (mixed Vision revisions).
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        guard (try? a.computeDistance(&d, to: b)) != nil else { return nil }
        return d
    }
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

// MARK: - Notch island

/// A Dynamic Island that grows out of the MacBook notch, speaking two visual
/// grammars. Compact: quick events live in the wings beside the notch, a glyph
/// on the left and a short tinted word on the right, at notch height. Tray:
/// standing states open a full panel below the notch with a screenshot
/// thumbnail, title, instruction subtitle, and the countdown ring.
///
/// The hosting window is a fixed transparent canvas; one CAShapeLayer slab
/// morphs between silhouettes with a real spring. The flared-top shape is the
/// boring.notch family look, implemented independently. At rest nothing draws
/// except the ember heartbeat when peers are connected.
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
        case compact(symbol: String?, tint: NSColor, word: String)
        case tray(image: NSImage?, symbol: String?, tint: NSColor,
                  title: String, subtitle: String, deadline: Date?, total: TimeInterval)
    }

    private let window: NSWindow
    private let canvas = NSView()
    private let slab = CAShapeLayer()
    private let ember = CALayer()

    // Compact face: wings beside the notch.
    private let wingView = NSView()
    private let wingIcon = NSImageView()
    private let wingLabel = NSTextField(labelWithString: "")

    // Tray face: panel below the notch.
    private let trayView = NSView()
    private let trayThumb = NSImageView()
    private let trayWell = NSView()
    private let trayWellIcon = NSImageView()
    private let trayTitle = NSTextField(labelWithString: "")
    private let traySub = NSTextField(labelWithString: "")
    private let ringView = NSView()
    private let ringTrack = CAShapeLayer()
    private let ringArc = CAShapeLayer()

    private var collapseWork: DispatchWorkItem?
    private var persistentFace: Face?
    private var connectedCount = 0
    private var expanded = false
    private var hovering = false
    private var sensorWindow: NSWindow?
    private let sensorView = NotchSensorView()

    /// Supplies the hover tray's content. Set by the app layer.
    var statusProvider: () -> (title: String, subtitle: String) = { ("Slingshot", "") }
    /// A file was dropped on the notch. Set by the app layer.
    var onDropFile: (URL) -> Void = { _ in }

    private let trayBand: CGFloat = 64
    private let canvasWidth: CGFloat = 800
    private let canvasHeight: CGFloat = 140
    private let topFlare: CGFloat = 8
    private let bottomRadius: CGFloat = 18

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

        slab.fillColor = NSColor.clear.cgColor
        slab.strokeColor = NSColor.clear.cgColor
        slab.lineWidth = 1
        slab.shadowColor = NSColor.black.cgColor
        slab.shadowOpacity = 0
        slab.shadowRadius = 12
        slab.shadowOffset = CGSize(width: 0, height: -5)
        canvas.layer?.addSublayer(slab)

        ember.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        ember.cornerRadius = 2
        ember.backgroundColor = Palette.ice.cgColor
        ember.shadowColor = Palette.ice.cgColor
        ember.shadowRadius = 4
        ember.shadowOpacity = 0.9
        ember.shadowOffset = .zero
        ember.isHidden = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.25
        pulse.toValue = 0.75
        pulse.duration = 2.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ember.add(pulse, forKey: "breathe")
        canvas.layer?.addSublayer(ember)

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
        trayThumb.imageScaling = .scaleProportionallyUpOrDown
        trayThumb.wantsLayer = true
        trayThumb.layer?.cornerRadius = 8
        trayThumb.layer?.cornerCurve = .continuous
        trayThumb.layer?.masksToBounds = true
        trayThumb.layer?.borderWidth = 1
        trayThumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
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
        trayTitle.lineBreakMode = .byTruncatingTail
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
        trayView.addSubview(ringView)

        sensorView.registerForDraggedTypes([.fileURL])
        sensorView.onEnter = { [weak self] in self?.hoverPeek() }
        sensorView.onExit = { [weak self] in self?.hoverEnd() }
        sensorView.onDragEnter = { [weak self] in
            self?.collapseWork?.cancel()
            self?.show(.tray(image: nil, symbol: "plus.circle.fill", tint: Palette.ice,
                             title: "Drop to hold",
                             subtitle: "Release, then fist and open at another Mac",
                             deadline: nil, total: 0))
        }
        sensorView.onDrop = { [weak self] url in self?.onDropFile(url) }

        reanchor()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reanchor()
        }
    }

    /// Hover over the notch: peek at status, unless a hold is already showing.
    private func hoverPeek() {
        hovering = true
        guard persistentFace == nil else { return }
        collapseWork?.cancel()
        let status = statusProvider()
        show(.tray(image: nil, symbol: "hand.raised.fill", tint: Palette.ice,
                   title: status.title, subtitle: status.subtitle, deadline: nil, total: 0))
    }

    private func hoverEnd() {
        hovering = false
        scheduleSettle(after: 0.3)
    }

    /// Pin the fixed canvas over the current notch (or top-center, notchless).
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
        slab.frame = canvas.bounds

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
            slab.path = collapsedPath()
        } else if let face = persistentFace {
            show(face)
        }
        updateEmber()
    }

    /// The island silhouette: top edge widest, concave flares at the top
    /// corners, convex rounds at the bottom. Constant segment structure, so
    /// paths interpolate cleanly in a spring.
    private func slabPath(centerX: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
        let minX = centerX - width / 2
        let maxX = centerX + width / 2
        let topY = slabTop
        let bottomY = slabTop - height
        let tr = min(topFlare, width / 4, height / 2)
        let br = min(bottomRadius, width / 4 - tr, height / 2)

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

    private func morph(to path: CGPath, spring: Bool) {
        let from = slab.presentation()?.path ?? slab.path
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
            ba.duration = 0.25
            ba.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim = ba
        }
        slab.path = path
        slab.add(anim, forKey: "morph")
    }

    // MARK: Public API

    /// Quick event: glyph in the left wing, short tinted word in the right wing.
    func compact(_ symbol: String?, _ tint: NSColor, _ word: String, seconds: TimeInterval = 2.2) {
        show(.compact(symbol: symbol, tint: tint, word: word))
        scheduleSettle(after: seconds)
    }

    /// Standing state or rich moment: thumbnail, title, subtitle, optional ring.
    func tray(image: NSImage?, symbol: String?, tint: NSColor, title: String, subtitle: String,
              deadline: Date?, total: TimeInterval, persist: Bool, seconds: TimeInterval = 5) {
        let face = Face.tray(image: image, symbol: symbol, tint: tint,
                             title: title, subtitle: subtitle, deadline: deadline, total: total)
        if persist {
            persistentFace = face
            collapseWork?.cancel()
            show(face)
        } else {
            show(face)
            scheduleSettle(after: seconds)
        }
    }

    func clearPersist() {
        persistentFace = nil
        collapseWork?.cancel()
        collapse()
    }

    func setPresence(_ connected: Int) {
        connectedCount = connected
        updateEmber()
    }

    func transient(_ text: String, for seconds: TimeInterval = 2.6) {
        compact(nil, Palette.ash, String(text.prefix(28)), seconds: seconds)
    }

    // MARK: Choreography

    private func scheduleSettle(after seconds: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func settle() {
        if let face = persistentFace {
            show(face)
        } else {
            collapse()
        }
    }

    private func updateEmber() {
        ember.isHidden = expanded || connectedCount == 0 || !hasNotch
        if !ember.isHidden {
            ember.position = CGPoint(x: canvasWidth / 2, y: slabTop - notchHeight + 5)
        }
    }

    private func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func materialize() {
        slab.fillColor = NSColor.black.cgColor
        slab.strokeColor = NSColor.white.withAlphaComponent(0.09).cgColor
        slab.shadowOpacity = 0.5
        expanded = true
        updateEmber()
    }

    private func show(_ face: Face) {
        switch face {
        case let .compact(symbol, tint, word):
            showCompact(symbol: symbol, tint: tint, word: word)
        case let .tray(image, symbol, tint, title, subtitle, deadline, total):
            showTray(image: image, symbol: symbol, tint: tint, title: title,
                     subtitle: subtitle, deadline: deadline, total: total)
        }
    }

    private func showCompact(symbol: String?, tint: NSColor, word: String) {
        materialize()
        trayView.alphaValue = 0

        let h = max(notchHeight, 26)
        let wordW = width(of: word, font: wingLabel.font ?? NSFont.systemFont(ofSize: 11))
        let leftWing: CGFloat = symbol != nil ? 8 + 18 + 8 : 10
        let rightWing: CGFloat = 10 + wordW + 12
        let w = notchWidth + leftWing + rightWing
        let centerX = canvasWidth / 2 + (rightWing - leftWing) / 2

        wingView.frame = NSRect(x: centerX - w / 2, y: slabTop - h, width: w, height: h)
        wingIcon.isHidden = symbol == nil
        if let symbol {
            wingIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            wingIcon.contentTintColor = tint
            wingIcon.frame = NSRect(x: 8, y: (h - 18) / 2, width: 18, height: 18)
        }
        wingLabel.stringValue = word
        wingLabel.textColor = tint
        wingLabel.frame = NSRect(x: w - wordW - 12, y: (h - 14) / 2, width: wordW, height: 14)

        morph(to: slabPath(centerX: centerX, width: w, height: h), spring: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wingView.animator().alphaValue = 1
        }
    }

    private func showTray(image: NSImage?, symbol: String?, tint: NSColor, title: String,
                          subtitle: String, deadline: Date?, total: TimeInterval) {
        materialize()
        wingView.alphaValue = 0

        let hasRing = deadline != nil
        let leadW: CGFloat = image != nil ? 52 : (symbol != nil ? 32 : 0)
        let textW = max(width(of: title, font: trayTitle.font ?? NSFont.systemFont(ofSize: 13)),
                        width(of: subtitle, font: traySub.font ?? NSFont.systemFont(ofSize: 11)))
        var w = 16 + (leadW > 0 ? leadW + 12 : 0) + min(textW, 320) + 16
        if hasRing { w += 24 + 14 }
        w = min(max(w, notchWidth + 120), canvasWidth - 24)
        let h = notchHeight + trayBand

        trayView.frame = NSRect(x: (canvasWidth - w) / 2, y: slabTop - h, width: w, height: trayBand)
        var x: CGFloat = 16
        trayThumb.isHidden = image == nil
        trayWell.isHidden = !(image == nil && symbol != nil)
        if let image {
            trayThumb.image = image
            trayThumb.frame = NSRect(x: x, y: (trayBand - 34) / 2, width: 52, height: 34)
            x += 52 + 12
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
            x += 32 + 12
        }
        let ringSpace: CGFloat = hasRing ? 24 + 14 : 0
        let textWidth = w - x - 16 - ringSpace
        trayTitle.stringValue = title
        trayTitle.frame = NSRect(x: x, y: trayBand / 2 + 2, width: textWidth, height: 17)
        traySub.stringValue = subtitle
        traySub.frame = NSRect(x: x, y: trayBand / 2 - 16, width: textWidth, height: 14)

        ringView.isHidden = !hasRing
        if let deadline {
            ringView.frame = NSRect(x: w - 24 - 14, y: (trayBand - 24) / 2, width: 24, height: 24)
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

    private func collapse() {
        expanded = false
        NSAnimationContext.runAnimationGroup({ [weak self] ctx in
            ctx.duration = 0.16
            self?.wingView.animator().alphaValue = 0
            self?.trayView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.morph(to: self.collapsedPath(), spring: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                guard let self, !self.expanded else { return }
                self.slab.fillColor = NSColor.clear.cgColor
                self.slab.strokeColor = NSColor.clear.cgColor
                self.slab.shadowOpacity = 0
                self.updateEmber()
            }
        })
    }
}

/// Neutral event banners route through the island.
func showToast(_ text: String) {
    NotchIsland.shared.transient(text)
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
    var onArmed: () -> Void = {}         // palm held long enough; fist will grab
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
                    onArmed()
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

// MARK: - Finger-snap listener

/// Fires onSnap when Apple's on-device sound classifier hears a finger snap.
/// All analysis is local; no audio leaves the Mac. Debounced so one snap fires once.
final class SnapListener: NSObject, SNResultsObserving {
    var onSnap: () -> Void = {}
    var confidenceThreshold: Double = 0.5
    var debounce: TimeInterval = 1.2

    private let audio = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private let queue = DispatchQueue(label: "slingshot.snap")
    private var lastFire = Date.distantPast

    func start() throws {
        guard !audio.isRunning else { return }
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RuntimeError("Microphone input unavailable")
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard request.knownClassifications.contains("finger_snapping") else {
            throw RuntimeError("Sound classifier has no finger_snapping class")
        }
        // High overlap trades a little CPU for catching a snap anywhere in the window.
        request.overlapFactor = 0.75
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer
        self.request = request

        input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, when in
            self?.queue.async {
                self?.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
            }
        }
        audio.prepare()
        try audio.start()
        log("🫰 Listening for finger snaps. A snap copies a screenshot to the clipboard")
    }

    func stop() {
        guard audio.isRunning else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        analyzer?.removeAllRequests()
        analyzer = nil
        request = nil
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let snap = result.classification(forIdentifier: "finger_snapping"),
              snap.confidence >= confidenceThreshold else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= debounce else { return }
        lastFire = now
        DispatchQueue.main.async { [weak self] in self?.onSnap() }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        log("❌ Snap listener failed: \(error.localizedDescription)")
    }
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
    struct RemoteHold {
        let deadline: Date
        let mode: TransferMode
        let face: VNFeaturePrintObservation?
    }

    private var remoteHolders: [MCPeerID: RemoteHold] = [:]
    private var grabMutedUntil = Date.distantPast

    var isHolding: Bool { lock.withLock { heldFile != nil } }
    var grabMuted: Bool { lock.withLock { Date() < grabMutedUntil } }
    var hasRemoteHold: Bool {
        let now = Date()
        return lock.withLock { remoteHolders.values.contains { now < $0.deadline } }
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
    func hold(_ url: URL, mode: TransferMode, ownerFace: String?) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            log("📦 No peer connected. Screenshot saved locally at \(url.path)")
            DispatchQueue.main.async {
                NotchIsland.shared.compact("wifi.slash", NotchIsland.Palette.ash, "No Macs")
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
            NotchIsland.shared.compact("hourglass", NotchIsland.Palette.ash, "Expired")
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
                    NotchIsland.shared.compact("person.crop.circle.badge.questionmark", NotchIsland.Palette.amber, "Show face")
                }
                return
            }
            if let dist = FaceID.distance(ownerFace, myFace) {
                log(String(format: "   · face distance %.3f (match if at most %.2f)", dist, faceMatchThreshold))
                if dist > faceMatchThreshold {
                    log("🚫 Different person. Normal mode blocks this drop")
                    DispatchQueue.main.async {
                        play("Basso")
                        NotchIsland.shared.compact("person.crop.circle.badge.xmark", NotchIsland.Palette.coral, "Blocked")
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
                NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Unreachable")
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
        session.sendResource(at: url, withName: name, toPeer: peer) { error in
            if let error {
                log("❌ Send to \(peer.displayName) failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Send failed")
                }
            } else {
                log("✅ Delivered to \(peer.displayName)")
                DispatchQueue.main.async {
                    NotchIsland.shared.compact("checkmark.seal.fill", NotchIsland.Palette.mint, "Sent")
                    play("Purr")
                }
                scheduleWorkDoneSleep()
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
                sendControl(["t": "unhold"])  // the hold is spoken for; stand everyone down
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
                NotchIsland.shared.compact("tortoise.fill", NotchIsland.Palette.coral, "Too late")
            }
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
                NotchIsland.shared.tray(image: NSImage(contentsOf: savedDest), symbol: "checkmark.seal.fill",
                                        tint: NotchIsland.Palette.mint,
                                        title: "From \(cleanName(id.displayName))",
                                        subtitle: "Saved to Downloads",
                                        deadline: nil, total: 0, persist: false)
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
        scheduleWorkDoneSleep()
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
        NotchIsland.shared.setPresence(connected.count)
        let fist = (camera?.isRunning ?? false) ? "✊" : "🫰"
        let base = connected.isEmpty ? "\(fist)…" : "\(fist) \(connected.count)"
        item.button?.title = base + (currentMode == .normal ? " N" : " P")

        let menu = NSMenu()
        menu.addItem(withTitle: "Slingshot v1.6", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Mode", action: nil, keyEquivalent: "")
        let normalItem = NSMenuItem(title: "Normal: face match required to catch", action: #selector(setNormal), keyEquivalent: "")
        normalItem.target = self
        normalItem.state = (currentMode == .normal) ? .on : .off
        menu.addItem(normalItem)
        let proItem = NSMenuItem(title: "Pro: anyone can catch", action: #selector(setPro), keyEquivalent: "")
        proItem.target = self
        proItem.state = (currentMode == .pro) ? .on : .off
        menu.addItem(proItem)
        menu.addItem(.separator())

        let cameraState = (camera?.isRunning ?? false) ? "Camera awake" : "Camera asleep. Snap to wake"
        menu.addItem(withTitle: cameraState, action: nil, keyEquivalent: "")
        let wakeItem = NSMenuItem(title: "Snap wakes the camera", action: #selector(toggleSnapWake), keyEquivalent: "")
        wakeItem.target = self
        wakeItem.state = snapWakeEnabled ? .on : .off
        menu.addItem(wakeItem)
        let snapItem = NSMenuItem(title: "Snap fingers for a clipboard screenshot", action: #selector(toggleSnap), keyEquivalent: "")
        snapItem.target = self
        snapItem.state = snapToClipboardEnabled ? .on : .off
        menu.addItem(snapItem)
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

    @objc private func setNormal() {
        currentMode = .normal
        log("🔒 Mode: Normal. Only the person who grabs can catch")
        refresh()
    }

    @objc private func setPro() {
        currentMode = .pro
        log("🔗 Mode: Pro. Anyone at any connected Mac can catch")
        refresh()
    }

    @objc private func toggleSnap() {
        snapToClipboardEnabled.toggle()
        UserDefaults.standard.set(snapToClipboardEnabled, forKey: "snapToClipboard")
        if snapToClipboardEnabled {
            log("🫰 Snap-to-clipboard on")
            startSnapListening()
        } else {
            log("🔇 Snap-to-clipboard off")
            if !snapWakeEnabled {
                snapListener?.stop()
                snapListener = nil
            }
        }
        refresh()
    }

    @objc private func toggleSnapWake() {
        snapWakeEnabled.toggle()
        UserDefaults.standard.set(snapWakeEnabled, forKey: "snapWake")
        if snapWakeEnabled {
            log("🫰 Snap-to-wake on. The camera sleeps when idle")
            startSnapListening()
            scheduleWorkDoneSleep()
        } else {
            log("👁️ Camera always on")
            wakeCamera("always-on mode")
            if !snapToClipboardEnabled {
                snapListener?.stop()
                snapListener = nil
            }
        }
        refresh()
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

// MARK: - Main

log("Slingshot v1.6. Palm then fist to sling a screenshot; snap your fingers for a clipboard copy")

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
var snapWakeEnabled: Bool = {
    // Default on: the camera sleeps until a snap wakes it.
    UserDefaults.standard.object(forKey: "snapWake") == nil || UserDefaults.standard.bool(forKey: "snapWake")
}()

func wakeCamera(_ reason: String) {
    guard let cam = camera, !cam.isRunning else { return }
    do {
        try cam.start()
        frameStore.markHand()
        log("👁️ Camera awake (\(reason))")
        DispatchQueue.main.async {
            play("Tink")
            NotchIsland.shared.compact("eye.fill", NotchIsland.Palette.ice, "Awake")
            statusUI?.refresh()
        }
    } catch {
        log("❌ Camera failed to wake: \(error)")
    }
}

func sleepCamera(_ reason: String) {
    guard snapWakeEnabled, let cam = camera, cam.isRunning else { return }
    guard !link.isHolding, !link.hasRemoteHold else { return }
    cam.stop()
    frameStore.clear()
    log("😴 Camera asleep (\(reason)). Snap to wake")
    DispatchQueue.main.async {
        NotchIsland.shared.compact("moon.zzz.fill", NotchIsland.Palette.ash, "Asleep")
        statusUI?.refresh()
    }
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
                        NotchIsland.shared.compact("doc.on.clipboard.fill", NotchIsland.Palette.mint, "Copied")
                    } else {
                        NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Failed")
                    }
                }
            }
        }
        do {
            try listener.start()
            snapListener = listener
        } catch {
            log("❌ Snap listener did not start: \(error)")
        }
    }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        begin()
    case .notDetermined:
        log("… Waiting for microphone approval (snap-to-clipboard)")
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if ok {
                    begin()
                } else {
                    log("🎤 Microphone denied. Snap features stay off")
                    NotchIsland.shared.compact("mic.slash.fill", NotchIsland.Palette.ash, "Mic off")
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
        NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.amber, "No screen access", seconds: 5)
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
            NotchIsland.shared.compact("arrow.down.circle.fill", NotchIsland.Palette.amber, "Open hand")
        }
    }

    engine.onArmed = {
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
                    NotchIsland.shared.compact("exclamationmark.triangle.fill", NotchIsland.Palette.coral, "Failed")
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
            NotchIsland.shared.compact("moon.zzz.fill", NotchIsland.Palette.ash, "Snap to wake", seconds: 4)
        }
    } else {
        wakeCamera("always-on mode")
    }

    // Doze off after 30 seconds without a hand in view and nothing pending.
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
        guard snapWakeEnabled, let cam = camera, cam.isRunning else { return }
        if Date().timeIntervalSince(frameStore.lastHand()) > 30 {
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
