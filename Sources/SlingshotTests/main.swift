// Dependency-free test runner for SlingshotCore. Runs everywhere the
// toolchain does, no Xcode required: swift run SlingshotTests
import AppKit
import CoreGraphics
import Foundation
import SlingshotCore
import SlingshotUI

var failures = 0

func expect(_ condition: Bool, _ name: String, _ message: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name): \(message)")
    }
}

let still = CGPoint(x: 0.5, y: 0.5)

func feed(_ engine: GestureEngine, _ pose: HandPose, times: Int, wrist: CGPoint? = nil) {
    for _ in 0..<times {
        engine.update(pose: pose, wrist: wrist ?? still)
    }
}

func quietEngine() -> GestureEngine {
    let engine = GestureEngine()
    engine.debugLogging = false
    return engine
}

// Arms after a steady palm
do {
    let engine = quietEngine()
    var armed = false
    engine.onArmed = { armed = true }
    feed(engine, .open, times: 30)
    expect(armed, "armsAfterSteadyPalm", "30 steady open frames should arm")
}

// Grabs after an armed fist
do {
    let engine = quietEngine()
    var grabbed = false
    engine.onGrab = { grabbed = true }
    feed(engine, .open, times: 30)
    feed(engine, .fist, times: 15)
    expect(grabbed, "grabAfterArmedFist", "1 second of steady fist after arming should grab")
}

// A waving hand never arms
do {
    let engine = quietEngine()
    var armed = false
    engine.onArmed = { armed = true }
    for i in 0..<60 {
        engine.update(pose: .open, wrist: CGPoint(x: i % 2 == 0 ? 0.2 : 0.8, y: 0.5))
    }
    expect(!armed, "movingWristNeverArms", "a waving hand must not arm")
}

// Dropped frames within grace do not reset arming
do {
    let engine = quietEngine()
    var armed = false
    engine.onArmed = { armed = true }
    feed(engine, .open, times: 20)
    feed(engine, .unknown, times: 3)
    feed(engine, .open, times: 10)
    expect(armed, "graceSurvivesDroppedFrames", "a few dropped frames must not punish an honest palm")
}

// Suppression feedback when grabbing is paused
do {
    let engine = quietEngine()
    engine.grabAllowed = { false }
    var suppressed = false
    var armed = false
    engine.onGrabSuppressed = { suppressed = true }
    engine.onArmed = { armed = true }
    feed(engine, .open, times: 20)
    expect(suppressed, "suppressionFeedback", "a steady palm while paused should surface feedback")
    expect(!armed, "suppressionBlocksArming", "grabbing must stay disabled while paused")
}

// Release requires a pending hold
do {
    let engine = quietEngine()
    engine.grabAllowed = { false }
    engine.releaseAllowed = { false }
    var released = false
    engine.onRelease = { released = true }
    feed(engine, .fist, times: 15)
    feed(engine, .open, times: 8)
    expect(!released, "releaseRequiresAllowed", "release must not fire when no hold is pending")
}

// The catch sequence primes then fires
do {
    let engine = quietEngine()
    engine.grabAllowed = { false }
    engine.releaseAllowed = { true }
    var primed = false
    var released = false
    engine.onReleasePrimed = { primed = true }
    engine.onRelease = { released = true }
    feed(engine, .fist, times: 15)
    expect(primed, "releasePrimes", "1 second of fist should prime the release")
    feed(engine, .open, times: 8)
    expect(released, "releaseFires", "opening the hand after the primed fist should release")
}

// Sound routing: a clean snap fires the snap action
do {
    let route = routeSoundWindow(snapConfidence: 0.8, clapConfidence: 0.1,
                                 snapEnabled: true, clapEnabled: true)
    expect(route == .snap, "routesCleanSnap", "snap 0.8 vs clap 0.1 should route to snap")
}

// Sound routing: the higher-confidence class wins the window
do {
    let route = routeSoundWindow(snapConfidence: 0.55, clapConfidence: 0.7,
                                 snapEnabled: true, clapEnabled: true)
    expect(route == .clap, "higherClassWins", "clap 0.7 should beat snap 0.55 when both are enabled")
}

// Sound routing: a disabled class never wins the window
do {
    let route = routeSoundWindow(snapConfidence: 0.55, clapConfidence: 0.9,
                                 snapEnabled: true, clapEnabled: false)
    expect(route == .snap, "disabledClassCannotWin",
           "with clap disabled, a snap-worthy window must still fire the snap")
}

// Sound routing: nothing eligible, nothing fires
do {
    let quiet = routeSoundWindow(snapConfidence: 0.3, clapConfidence: 0.2,
                                 snapEnabled: true, clapEnabled: true)
    expect(quiet == nil, "quietWindowFiresNothing", "sub-threshold confidences must route nowhere")
    let disabled = routeSoundWindow(snapConfidence: 0.9, clapConfidence: 0.9,
                                    snapEnabled: false, clapEnabled: false)
    expect(disabled == nil, "allDisabledFiresNothing", "no enabled action means no route")
}

// Sound routing: claps clear their own lower bar
do {
    let route = routeSoundWindow(snapConfidence: 0.1, clapConfidence: 0.4,
                                 snapEnabled: true, clapEnabled: true)
    expect(route == .clap, "clapLowerBar", "clap 0.4 is over the 0.35 clap bar and should fire")
}

// MARK: - UI geometry invariants
// These reproduce the exact bug classes we shipped and caught by eye:
// overlapping footer controls, content clipped by bands, and island content
// drawn inside the physical notch where no pixels exist.

if NSScreen.screens.isEmpty {
    print("SKIP  UI geometry (no display attached)")
} else {
    _ = NSApplication.shared

    func within(_ inner: CGRect, _ outer: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        outer.insetBy(dx: -tolerance, dy: -tolerance).contains(inner)
    }
    func disjoint(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        !a.insetBy(dx: tolerance, dy: tolerance).intersects(b.insetBy(dx: tolerance, dy: tolerance))
    }

    // Island: compact face keeps its content on the wings, never in the notch
    let island = NotchIsland.shared
    island.compact("hand.raised.fill", NotchIsland.Palette.amber, "Armed", kind: .status, seconds: 0.05)
    var snap = island._testSnapshot()
    expect(!snap.wingContentFrames.isEmpty, "compactHasContent", "a compact face should lay out wing content")
    for frame in snap.wingContentFrames {
        expect(within(frame, snap.slabBounds), "wingInsideSlab", "wing content must sit inside the slab silhouette")
        expect(disjoint(frame, snap.notchBand), "wingClearOfNotch", "wing content must never enter the physical notch band")
    }

    // Let the compact transient expire so the persistent tray may display
    Thread.sleep(forTimeInterval: 0.1)

    // Island: a tray with a long peer name stays inside the slab, below the notch
    island.tray(image: nil, symbol: "tray.and.arrow.down.fill", tint: NotchIsland.Palette.mint,
                title: "Adityas MacBook Air with an unreasonably long machine name is holding",
                subtitle: "Fist 1 second, then open your hand to catch",
                deadline: Date().addingTimeInterval(30), total: 30, persist: true)
    snap = island._testSnapshot()
    expect(!snap.trayContentFrames.isEmpty, "trayHasContent", "a tray face should lay out tray content")
    for frame in snap.trayContentFrames {
        expect(within(frame, snap.slabBounds), "trayInsideSlab", "tray content must sit inside the slab silhouette; frame \(frame) slab \(snap.slabBounds)")
        expect(frame.maxY <= snap.notchBand.minY + 0.5, "trayBelowNotch", "tray content must render below the notch band")
    }
    for (i, a) in snap.trayContentFrames.enumerated() {
        for b in snap.trayContentFrames[(i + 1)...] {
            expect(disjoint(a, b), "trayContentDisjoint", "tray elements must never overlap each other")
        }
    }
    island.clearPersist()

    // Island: peer beads sit on live pixels below the notch, one per peer
    island.setPresence(3)
    snap = island._testSnapshot()
    expect(snap.beadPositions.count == 3, "beadPerPeer", "three peers should show three beads")
    for bead in snap.beadPositions {
        expect(bead.y < snap.notchBand.minY, "beadBelowNotch",
               "beads must render below the notch band, where pixels exist")
    }
    island.setPresence(0)

    // Welcome window: every top-level element inside the window, none overlapping
    let content = OnboardingWindow.shared._testContentView()
    let elements = content.subviews.filter { !$0.isHidden }
    expect(elements.count >= 12, "welcomeBuilt", "the welcome window should lay out its full band structure")
    for view in elements {
        expect(within(view.frame, content.bounds), "welcomeInBounds",
               "\(type(of: view)) at \(view.frame) must stay inside the window")
    }
    for (i, a) in elements.enumerated() {
        for b in elements[(i + 1)...] {
            expect(disjoint(a.frame, b.frame), "welcomeNoOverlap",
                   "\(type(of: a)) \(a.frame) and \(type(of: b)) \(b.frame) must not overlap")
        }
    }

    // Snapshot gallery: render the states we just asserted, best effort
    let snapshotsDir = URL(fileURLWithPath: "snapshots", isDirectory: true)
    try? FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
    func writePNG(_ view: NSView, _ name: String) {
        let stage = NSWindow(contentRect: NSRect(x: -20000, y: -20000,
                                                 width: view.frame.width, height: view.frame.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
        stage.contentView = view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: snapshotsDir.appendingPathComponent(name))
        }
        stage.contentView = nil
    }
    writePNG(OnboardingWindow.shared._testContentView(), "welcome.png")
    island.tray(image: nil, symbol: "square.and.arrow.up.fill", tint: NotchIsland.Palette.ice,
                title: "Holding screenshot", subtitle: "Fist 1 second, then open your hand at another Mac",
                deadline: Date().addingTimeInterval(30), total: 30, persist: true)
    print("NOTE  snapshots written to snapshots/ (welcome.png)")
    island.clearPersist()
}

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All tests passed")
