# Slingshot

**Grab your Mac's screen with a fist. Watch it land on your friend's Mac.**

Inspired by Huawei's Mate 70 air-gesture file transfer demo — rebuilt for the Apple ecosystem in a single evening. Show your open palm to the camera, close your fist, and a screenshot of your desktop flies to every nearby Mac running the app: camera flash, shrink-away animation on your screen, zoom-in arrival with a chime on theirs.

https://github.com/Giri-Aayush/slingshot

## How it works

- **Gesture detection** — Apple's Vision framework (`VNDetectHumanHandPoseRequest`) tracks 21 hand joints from the FaceTime camera at ~15 fps. A small state machine arms on ~0.4 s of open palm (Tink sound), then fires on ~0.13 s of closed fist (Pop sound). Fingertips that Vision loses sight of count as curled — that's what makes fist detection robust when fingers occlude themselves.
- **Screenshot** — `/usr/sbin/screencapture` grabs the full desktop to `~/Pictures/Slingshot/`.
- **Transfer** — MultipeerConnectivity (the same local Wi-Fi / peer-to-peer transport AirDrop uses). Peers auto-discover on the local network, auto-connect (with 8 s retries), and stream the PNG. Received files land in `~/Downloads` as `from-<sender>-grab-<timestamp>.png` and open automatically.
- **Feedback** — menu bar icon (✊… searching / ✊✓ connected), toast banners for connect/send/receive/errors, flash + fly-away animation on grab, zoom-up animation on receive.

There is no sender or receiver role — every copy of the app does both. Real AirDrop has no programmatic-send API, which is why the transfer layer is MultipeerConnectivity.

## Install (prebuilt)

1. Download `Slingshot.zip` from [Releases](https://github.com/Giri-Aayush/slingshot/releases) and unzip.
2. The app is signed with a development certificate, not notarized, so Gatekeeper will balk. Either:
   - run `xattr -dr com.apple.quarantine /path/to/Slingshot.app`, or
   - try to open it once, then System Settings → Privacy & Security → scroll to Security → **Open Anyway**.
3. Open the app. Approve the **Camera** prompt and **Local Network** prompt.
4. Grant **Screen Recording** (System Settings → Privacy & Security → Screen & System Audio Recording → enable Slingshot), then quit and reopen the app — that permission only applies at launch.
5. Look for the **✊ icon in the menu bar**. When a second Mac on the same Wi-Fi runs the app, it flips to ✊✓ within seconds.

Then: palm at the camera, hold half a second, make a fist. 👋 → ✊ → 🚀

## Build from source

```bash
swift build -c release
mkdir -p Slingshot.app/Contents/MacOS
cp Info.plist Slingshot.app/Contents/Info.plist
cp .build/release/Slingshot Slingshot.app/Contents/MacOS/Slingshot
codesign --force -s "<your signing identity>" Slingshot.app
open Slingshot.app
```

Requires macOS 13+, Swift 5.9+. Sign with a real certificate (`security find-identity -v -p codesigning`), **not** ad-hoc (`-s -`): TCC ties Screen Recording grants to the code signature, and an ad-hoc signature changes on every rebuild — the Settings toggle will show "on" while silently failing. If you hit that state, `tccutil reset ScreenCapture com.aayush.slingshot` and re-grant.

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

- Grab the frontmost Finder selection / any file, not just screenshots
- Receiver-side "open palm to catch" gesture (two-sided handshake like the original Huawei demo)
- Proper notarized distribution
- iPad support (same Vision + MultipeerConnectivity APIs)

## License

MIT
