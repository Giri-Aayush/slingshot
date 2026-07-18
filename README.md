# Slingshot

**Grab your Mac's screen with a fist. Watch it land on your friend's Mac.**

Inspired by Huawei's Mate 70 air-gesture file transfer demo, rebuilt for the Apple ecosystem. Hold your palm open and still for two seconds, then hold your fist for one second: camera flash, and a screenshot of your desktop is now *held in your hand*. Nothing is sent yet. Walk to the Mac you want it on and open your fist at its camera: it catches the drop, the file transfers to that Mac only, and zooms up on its screen with a chime. Don't drop it anywhere within 30 seconds and it quietly stays in your Pictures folder.

https://github.com/Giri-Aayush/slingshot

## How it works

- **Gesture detection**: Apple's Vision framework (`VNDetectHumanHandPoseRequest`) tracks 21 hand joints from the FaceTime camera at ~15 fps. Gestures are deliberate by design: 2 s of steady open palm arms (Tink), 1 s of held fist grabs (Pop), and a drop is 1 s of fist then half a second of open hand. A moving wrist resets the timers, so waving or talking with your hands never triggers anything. Fingertips that Vision loses sight of count as curled, which keeps fist detection solid when fingers occlude themselves.
- **Screenshot**: `/usr/sbin/screencapture` grabs the full desktop to `~/Pictures/Slingshot/`.
- **Hold & catch**: a grab doesn't broadcast anything. The grabbing Mac keeps the file and tells peers "I'm holding". When another Mac's camera sees the release gesture (fist for 1 s, then open hand) within 30 s, it claims the drop and only then does the file stream to it, via MultipeerConnectivity (the same local Wi-Fi / peer-to-peer transport AirDrop uses; auto-discover, auto-connect, 8 s retries). Received files land in `~/Downloads` as `from-<sender>-grab-<timestamp>.png` and open automatically.
- **Notch island**: feedback lives in a Dynamic Island style banner that grows out of the MacBook notch, black on black so it is invisible until something happens. It pulses for events (armed, caught, connected) and stays out while a hold is pending on either side. Macs without a notch get a floating pill instead.
- **Feedback**: menu bar icon (✊… searching / ✊✓ connected), toast banners for connect/send/receive/errors, flash + fly-away animation on grab, zoom-up animation on receive.

There is no sender or receiver role. Every copy of the app does both, and it is not limited to two Macs: everyone on the same network meshes together automatically (up to 8 per session). A hold is announced to every connected Mac, the first one to see the catch gesture wins the file, and latecomers are told someone beat them to it. The menu bar shows the whole room: a live count on the icon, plus Connected and Nearby sections. Real AirDrop has no programmatic-send API, which is why the transfer layer is MultipeerConnectivity.

## Install (prebuilt)

1. Download `Slingshot.zip` from [Releases](https://github.com/Giri-Aayush/slingshot/releases) and unzip.
2. The app is signed with a development certificate, not notarized, so Gatekeeper will balk. Either:
   - run `xattr -dr com.apple.quarantine /path/to/Slingshot.app`, or
   - try to open it once, then System Settings → Privacy & Security → scroll to Security → **Open Anyway**.
3. Open the app. Approve the **Camera** prompt and **Local Network** prompt.
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

- Grab the frontmost Finder selection / any file, not just screenshots
- Proper notarized distribution
- iPad support (same Vision + MultipeerConnectivity APIs)

## License

MIT
