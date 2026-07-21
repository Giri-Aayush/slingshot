import AppKit
import SlingshotCore
import SlingshotUI
import ServiceManagement
import Sparkle

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
        menu.addItem(withTitle: "Slingshot v2.3.1", action: nil, keyEquivalent: "")
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
        let clapItem = NSMenuItem(title: "Clap to mute or unmute the Mac", action: #selector(toggleClap), keyEquivalent: "")
        clapItem.target = self
        clapItem.state = clapMuteEnabled ? .on : .off
        menu.addItem(clapItem)
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
        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        let trustItem = NSMenuItem(title: "Reset trusted Macs", action: #selector(resetTrust), keyEquivalent: "")
        trustItem.target = self
        menu.addItem(trustItem)
        let welcomeItem = NSMenuItem(title: "Show Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)
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
        setSnapClipboard(!snapToClipboardEnabled)
        refresh()
    }

    @objc private func toggleSnapWake() {
        setSnapWake(!snapWakeEnabled)
        refresh()
    }

    @objc private func toggleClap() {
        setClapMute(!clapMuteEnabled)
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("🚪 Start at Login off")
            } else {
                try SMAppService.mainApp.register()
                log("🚪 Start at Login on")
            }
        } catch {
            log("❌ Start at Login change failed: \(error)")
        }
        refresh()
    }

    @objc private func resetTrust() {
        link.resetTrust()
        refresh()
    }

    @objc private func showWelcome() {
        OnboardingWindow.shared.show()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(shotsDir)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logFileURL)
    }
}

