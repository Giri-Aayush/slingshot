# Security Policy

Slingshot touches the camera, the microphone, the screen, and the local
network. We take reports about any of them seriously.

## Reporting a vulnerability

Email aayushgiri1234@gmail.com with "Slingshot security" in the subject.
Please do not open a public issue for anything exploitable. You will get an
acknowledgment within 72 hours and a status update within two weeks. If the
report is valid we will credit you in the release notes unless you prefer
otherwise.

## Scope

Things we consider security issues:

- Receiving or executing content a peer did not deliberately send
- Joining a mesh, catching a hold, or reading a transfer without being an
  intended participant
- Any path where audio, video, screenshots, or face data leave the Mac other
  than an encrypted transfer to a session peer
- Permission bypasses or misleading permission prompts

## What the app does, honestly

- The camera runs only while awake (snap-to-wake) and frames never leave the
  process.
- The microphone feeds Apple's on-device sound classifier; audio is never
  recorded or transmitted.
- Screenshots and dropped files are sent only to the peer that completes the
  catch gesture, over MultipeerConnectivity with encryption required.
- In Normal mode, a face feature print travels with a hold to session peers
  and is discarded when the hold ends. It is an image-similarity embedding,
  not a face-recognition identity, and is documented as best effort.
- There is no telemetry, no analytics, and no server.

## Known limitations

First-contact peer approval gates every connection, and received non-image
files are revealed in Finder rather than opened. The face lock remains best
effort and is documented as such.

## Supported versions

The latest release only.
