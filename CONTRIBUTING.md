# Contributing to Slingshot

Thanks for wanting to help. Slingshot is a small, opinionated codebase; this
page tells you how to work in it without friction.

## Build and run

```bash
swift build -c release
./scripts/package.sh          # assembles and signs Slingshot.app, produces Slingshot.zip
open Slingshot.app
```

Requires macOS 13+ and Swift 5.9+. Signing uses the identity in the
`CODESIGN_IDENTITY` environment variable, falling back to ad-hoc. Ad-hoc builds
work, but macOS ties Screen Recording permission to the signature, so every
rebuild needs the permission re-granted. Use a real certificate for iteration.

Logs narrate everything the app does: `~/Library/Logs/Slingshot.log`, also
reachable from the menu bar via Show Log. When filing or fixing a bug, the log
from both Macs is the single most useful artifact.

## Testing

```bash
swift run SlingshotTests
```

Unit tests live in `Sources/SlingshotTests` and cover the pure logic: the gesture state
machine and the hold ledger. UI and transport are exercised manually; a change
that touches the transfer protocol should be tested with two real Macs before
the PR, and say so in the description.

## Style

- Swift, AppKit, CoreAnimation. No new dependencies without discussion.
- No em dashes anywhere in user-facing copy: app strings, log lines, README,
  release notes. Short words in the island's compact state; sentences only in
  tray subtitles. Plain, human copy everywhere.
- Emoji are used in log lines as scannable markers; keep that convention.
- Comments state constraints the code cannot show, not narration.
- Commit messages: one imperative subject line, a short body saying why.

## Protocol changes

Control messages are JSON dictionaries over the MultipeerConnectivity session.
Unknown keys and unknown `t` values must be ignored by receivers, so older
peers degrade gracefully. If you add a message or field, state the
compatibility behavior in the PR.

## Pro features

Some features are gated by a lifetime license at runtime. The source stays MIT
and gates are honest checks, not obfuscation; anyone can build an ungated copy
from this repo. PRs may touch gated features like any other code.

## Sign-off

By submitting a PR you certify the
[Developer Certificate of Origin](https://developercertificate.org/): the work
is yours to contribute under the MIT license. Add `Signed-off-by` to your
commits (`git commit -s`).

## Releases

Maintainers cut releases by tagging `vX.Y.Z`. CI builds, tests, packages, and
attaches `Slingshot.zip` to the GitHub release. Release notes follow the same
copy rules as everything else.
