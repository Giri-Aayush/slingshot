# Slingshot

**Grab your Mac's screen with a fist. Watch it land on your friend's Mac.**

Inspired by Huawei's Mate 70 air-gesture file transfer demo, rebuilt for the Apple ecosystem. Hold your palm open and still for two seconds, then hold your fist for one second: camera flash, and a screenshot of your desktop is now *held in your hand*. Nothing is sent yet. Walk to the Mac you want it on and open your fist at its camera: it catches the drop, the file transfers to that Mac only, and zooms up on its screen with a chime. Don't drop it anywhere within 30 seconds and it quietly stays in your Pictures folder.

https://github.com/Giri-Aayush/slingshot

## Demo

A 30 second demo video is coming. Until then: snap, palm, fist, walk, fist, open hand. The screenshot crosses the room.

## How it works

- **The notch is alive**: hover your mouse over it and a status tray peeks out (connected Macs, camera state, mode). Drag any file onto the notch and Slingshot holds it exactly like a grabbed screenshot: walk to another Mac, fist for a second, open your hand, and the file lands there. Folders can't fly over MultipeerConnectivity; compress one and drop the zip instead, and the notch will tell you so.
- **Snap to wake** (on by default): the camera sleeps until Apple's on-device sound classifier hears a finger snap. Snap, an eye glyph blinks from the notch, and the hand gestures work as usual. It dozes back off a few seconds after a transfer completes, after 15 seconds without a hand in view, or the moment you clap, and an incoming hold wakes it automatically so catching needs no snap. Turn it off in the menu bar for an always-on camera. If the microphone is denied, the camera falls back to always-on.
- **Gesture detection**: Apple's Vision framework (`VNDetectHumanHandPoseRequest`) tracks 21 hand joints from the FaceTime camera at ~15 fps. Gestures are deliberate by design: 2 s of steady open palm arms (Tink), 1 s of held fist grabs (Pop), and a drop is 1 s of fist then half a second of open hand. A moving wrist resets the timers, so waving or talking with your hands never triggers anything. Fingertips that Vision loses sight of count as curled, which keeps fist detection solid when fingers occlude themselves.
- **Screenshot**: `/usr/sbin/screencapture` grabs the full desktop to `~/Pictures/Slingshot/`.
- **Snap to clipboard** (opt-in, off by default): Apple's on-device sound classifier listens for a finger snap and copies a full screenshot straight to the clipboard, ready for Cmd-V. Toggle it from the menu bar. Audio is analyzed locally and never leaves the Mac.
- **Clap actions**: by default a clap puts the camera to sleep, the mirror of snap-to-wake. Opt in to clap-to-mute from the menu bar and a clap instead toggles the Mac's output mute: clap to silence it, clap again to bring the sound back, with Muted and Sound on in the notch. Snaps and claps share one detector; only enabled features compete for a sound and the higher-confidence class wins, so one sound never triggers two actions. When a Bluetooth device holds the system input, Slingshot listens on the built-in microphone instead, because a far-field speaker mic hears neither snaps nor claps.
- **Transfer modes**: Normal locks the hold to the grabber's face. At grab time the app samples several frames, keeps the best three by Apple's face capture quality score, and measures how much your own face varies between them on your own camera; that measured spread sets the acceptance threshold, which travels with the hold instead of being a hard-coded constant. At the catching Mac the camera gets several looks over about a second and a half, and one match against any enrolled print completes the drop. This is a best-effort check built on Vision's image similarity, not a security boundary; the prints travel encrypted to session peers and are discarded when the hold ends. Pro mode lets anyone at any connected Mac catch.
- **Hold & catch**: a grab doesn't broadcast anything. The grabbing Mac keeps the file and tells peers "I'm holding". When another Mac's camera sees the release gesture (fist for 1 s, then open hand) within 30 s, it claims the drop and only then does the file stream to it, via MultipeerConnectivity (the same local Wi-Fi / peer-to-peer transport AirDrop uses; auto-discover, auto-connect, 8 s retries). Received files land in `~/Downloads` as `from-<sender>-grab-<timestamp>.png`; images open, anything else is revealed in Finder rather than launched.
- **Notch island**: feedback lives in a Dynamic Island style banner that grows out of the MacBook notch, black on black so it is invisible until something happens. It pulses for events (armed, caught, connected) and stays out while a hold is pending on either side. Macs without a notch get a floating pill instead.
- **Feedback**: menu bar icon (✊… searching / ✊✓ connected), toast banners for connect/send/receive/errors, flash + fly-away animation on grab, zoom-up animation on receive.

There is no sender or receiver role. Every copy of the app does both, and it is not limited to two Macs: Macs on the same network find each other, and the first contact asks on both screens before anything connects; approvals persist and can be reset from the menu bar (up to 8 per session). A hold is announced to every connected Mac, the first one to see the catch gesture wins the file, and latecomers are told someone beat them to it. The menu bar shows the whole room: a live count on the icon, plus Connected and Nearby sections. Real AirDrop has no programmatic-send API, which is why the transfer layer is MultipeerConnectivity.

## Install (prebuilt)

1. Download `Slingshot.zip` from [Releases](https://github.com/Giri-Aayush/slingshot/releases) and unzip. From v2.0 the app updates itself: signed updates arrive through Sparkle, and Check for Updates lives in the menu bar next to Start at Login.
2. The app is signed with a development certificate, not notarized, so Gatekeeper will balk. Either:
   - run `xattr -dr com.apple.quarantine /path/to/Slingshot.app`, or
   - try to open it once, then System Settings → Privacy & Security → scroll to Security → **Open Anyway**.
3. Open the app. Approve the **Camera** and **Local Network** prompts. Approve **Microphone** too: a snap is what wakes the camera (audio never leaves the Mac; disable snap-to-wake in the menu bar to skip this).
4. Grant **Screen Recording** (System Settings → Privacy & Security → Screen & System Audio Recording → enable Slingshot), then quit and reopen the app. That permission only applies at launch.
5. Look for the **✊ icon in the menu bar**. When a second Mac on the same Wi-Fi runs the app, it flips to ✊✓ within seconds.

Then: palm open and still for 2 s, fist for 1 s to grab. Walk over, fist for 1 s and open your hand at the other Mac to drop. 👋 → ✊ → 🚶 → 🫳 → 🎁

## Build from source

```bash
swift build -c release
mkdir -p Slingshot.app/Contents/MacOS
cp Info.plist Slingshot.app/Contents/Info.plist
cp .build/release/Slingshot Slingshot.app/Contents/MacOS/Slingshot
codesign --force -s "<your signing identity>" Slingshot.app
open Slingshot.app
```

Requires macOS 13+, Swift 5.9+. Sign with a real certificate (`security find-identity -v -p codesigning`), **not** ad-hoc (`-s -`): TCC ties Screen Recording grants to the code signature, and an ad-hoc signature changes on every rebuild. The Settings toggle will show "on" while silently failing. If you hit that state, `tccutil reset ScreenCapture com.aayush.slingshot` and re-grant.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Slingshot Not Opened / could not verify" | Strip quarantine: `xattr -dr com.apple.quarantine Slingshot.app` |
| Screenshot toggle on, but captures fail | Stale TCC grant from a re-signed build: `tccutil reset ScreenCapture com.aayush.slingshot`, reopen, re-grant |
| Screenshots only show wallpaper | Screen Recording not granted, or app not relaunched after granting |
| No ✊ in menu bar | You're running an old build, or camera permission was denied |
| Peers never connect | Same Wi-Fi? Firewall blocking incoming connections? Check `~/Library/Logs/Slingshot.log` on both sides |
| Gesture won't trigger | Face the camera, fingers spread, good lighting; the log prints per-frame finger measurements to tune thresholds |

Everything the app does is narrated in `~/Library/Logs/Slingshot.log` (also reachable from the menu bar → Show Log).

## Roadmap

- Notarized distribution (pipeline is in scripts/package.sh, waiting on a Developer ID certificate)
- iPad support (same Vision + MultipeerConnectivity APIs)

## Slingshot Pro

Slingshot is open source and the core experience is free forever: sling screenshots between two Macs with your hands, snap to wake, clap to sleep, the notch island, snap to clipboard, auto-updates. A one-time lifetime license unlocks the power features:

- **File drops**: drag any file onto the notch and carry it to another Mac
- **Bigger rooms**: three or more Macs in one mesh
- **The face lock**: Normal mode, where only the person who grabbed can catch
- **Clap to mute**: a clap toggles your Mac's sound instead of sleeping the camera

Buy once, keep it forever, updates included. Purchase link coming with the public launch; until then, licenses are issued by hand. Enter your key from the menu bar under Get Slingshot Pro.

Because the source is MIT, you can build every feature yourself from this repo. The license is for people who want the signed, auto-updating app and to keep this project alive. That trade is the whole business model, stated plainly.

## Project

- [Contributing](CONTRIBUTING.md), including build and test instructions
- [Security policy](SECURITY.md)
- [Privacy](PRIVACY.md): no server, no telemetry, nothing leaves the Mac except transfers

## License

MIT
