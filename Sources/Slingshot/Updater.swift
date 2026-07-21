import SlingshotCore
import AppKit
import SlingshotUI
import Sparkle

// Sparkle checks the appcast in the repo and installs signed updates.
// The feed lives on main so every release updates it in the same push.
let updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                     updaterDelegate: nil,
                                                     userDriverDelegate: nil)
