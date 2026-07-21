# Privacy

Slingshot is local software. There is no server, no account, no telemetry,
and no analytics. This page states exactly what the app touches and where it
goes.

**Camera.** Used to read hand gestures and, in Normal mode, to build a face
print at grab and catch time. Frames are processed in memory on the machine
and never stored or transmitted. With snap-to-wake on (the default), the
camera is off except during an active transfer window.

**Microphone.** Feeds Apple's on-device sound classifier to detect finger
snaps. Audio is never recorded, stored, or transmitted.

**Screen.** Screenshots are taken only when you perform the grab gesture or
the snap-to-clipboard action, and are saved to your own Pictures folder or
clipboard. They leave the Mac only when a peer completes the catch gesture.

**Transfers.** Files travel directly between Macs over MultipeerConnectivity
with encryption required, on your local network. Nothing is relayed through
any third party.

**Face data.** In Normal mode, a hold carries up to three Vision feature
prints of the grabber's face, sampled over about a second at grab time, so
the receiving Mac can check the catcher. They are sent encrypted to session
peers and discarded when the hold ends. They are image-similarity embeddings,
not biometric identity templates, and the check is documented as best effort
rather than a security boundary.

**Local records.** The app writes a log of its own activity to
~/Library/Logs/Slingshot.log and stores your preferences in UserDefaults.
Both stay on your Mac.
