import AppKit
import SlingshotCore
import SlingshotUI

// MARK: - Pro membership

/// The verified license, if any. Loaded at launch, set on key entry.
var proLicense: ProLicense? = validateLicense(UserDefaults.standard.string(forKey: "licenseKey") ?? "")

func isPro() -> Bool { proLicense != nil }

/// Gate a Pro feature. Returns true when licensed; otherwise shows the pitch
/// once per call site invocation and returns false. Free features never call this.
@discardableResult
func requirePro(_ feature: String) -> Bool {
    if isPro() { return true }
    log("🔒 \(feature) is a Slingshot Pro feature")
    DispatchQueue.main.async {
        NotchIsland.shared.compact("lock.fill", NotchIsland.Palette.amber, "Pro", kind: .outcome)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(feature) is part of Slingshot Pro"
        alert.informativeText = "One lifetime license unlocks file drops, bigger rooms, the face lock, and clap to mute, forever. The core app stays free."
        alert.addButton(withTitle: "Enter License Key")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            promptForLicenseKey()
        }
    }
    return false
}

func promptForLicenseKey() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Enter your Slingshot Pro key"
    alert.informativeText = "It starts with SLINGSHOT- and lives in your purchase email."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
    field.placeholderString = "SLINGSHOT-..."
    alert.accessoryView = field
    alert.addButton(withTitle: "Activate")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let key = field.stringValue
    if let license = validateLicense(key) {
        UserDefaults.standard.set(key, forKey: "licenseKey")
        proLicense = license
        log("✨ Slingshot Pro activated for \(license.email)")
        NotchIsland.shared.compact("checkmark.seal.fill", NotchIsland.Palette.mint, "Pro", kind: .outcome)
        statusUI?.refresh()
    } else {
        log("❌ License key did not validate")
        let bad = NSAlert()
        bad.messageText = "That key did not validate"
        bad.informativeText = "Check for missing characters, then try again. Reply to your purchase email if it keeps failing."
        bad.runModal()
    }
}

/// Free tier enforcement at launch: gated settings cannot survive a missing
/// license, however they were persisted.
func enforceFreeTier() {
    guard !isPro() else { return }
    if currentMode == .normal {
        currentMode = .pro
        log("🔒 Face lock needs Slingshot Pro. Mode set to open catching")
    }
    if clapMuteEnabled {
        clapMuteEnabled = false
        UserDefaults.standard.set(false, forKey: "clapMute")
        log("🔒 Clap-to-mute needs Slingshot Pro. A clap sleeps the camera")
    }
}
