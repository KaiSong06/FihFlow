# FihFlow in Boring Notch

The stable Boring Notch v2.7.3 has no public external-activity API. This optional
receiver renders FihFlow inside Boring Notch's own SwiftUI layout. It shows a
microphone and live meter while listening, a spinner while starting/processing,
and a stop button for toggle recording. Existing notch content returns afterward.
It covers FihFlow dictation; the separate Meeting Notes window is unchanged.

The adapter targets upstream commit `16b0f11f51c79d42e27c10d77fd9e53c11410fdb`
from [Boring Notch v2.7.3](https://github.com/TheBoredTeam/boring.notch/tree/v2.7.3).
It is not compatible with an unmodified Boring Notch binary. An upstream app
update replaces this receiver; FihFlow then falls back to its ordinary overlay.

## Build

From the FihFlow checkout (Xcode and upstream's Swift packages are required):

```sh
git clone --depth 1 --branch v2.7.3 https://github.com/TheBoredTeam/boring.notch.git build/boring-notch-source
python3 integrations/boring-notch/prepare.py build/boring-notch-source
xcodebuild -project build/boring-notch-source/boringNotch.xcodeproj \
  -scheme boringNotch -configuration Debug \
  -derivedDataPath build/boring-notch-derived \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
make APP_NAME=FihFlow BUNDLE_ID=com.kaisong.fihflow ARCH="$(uname -m)" CODESIGN_IDENTITY=-
```

Keep a recoverable copy of the installed Boring Notch app, quit it, then install
the build from `build/boring-notch-derived/Build/Products/Debug/boringNotch.app`.
Its bundle identifier and preferences remain the same. macOS may ask again for
permissions because the local build has a different signature; permission
changes must be approved by the user. This does not change signing settings in
either source project or publish a release.

Launch both apps. In FihFlow Settings → Recording Overlay, turn on **Show
dictation in Boring Notch**, then use **Preview animation**. Preview uses
simulated levels without accessing the microphone or an AI provider.

## Local protocol and fallback

The shared protocol is `Sources/NotchActivityProtocol.swift`. Distributed
notifications carry a bounded JSON object string with a version, ephemeral
session, sequence, process ID, phase, level, stop availability, and timestamp.
No transcript, audio, error text, credentials, or persistent files are shared.
The receiver checks the sender's app identifier and rejects stale/malformed
packets. This is a local UI coordination channel, not an authentication boundary.
It cannot start recording, paste, execute commands, or request transcription.

FihFlow waits up to 400 ms for the receiver, then restores its usual overlay if
there is no response. State expires after two seconds without a heartbeat.
Stopping requires a current matching session and active toggle recording.
The receiver clears itself if FihFlow quits or crashes. Turning the preference
off restores the ordinary overlay on the next dictation.

## Verification

`make check` covers payload validation, privacy field bounds, receiver lease
expiry, and type-checking the receiver. On 2026-11-06, both apps were built and
signature-verified locally. Cua Driver checks using the synthetic preview passed:

- Listening meter and processing ring render in Boring Notch's own window.
- FihFlow creates no second panel while the receiver is responding.
- The notch stop button ends the preview before its automatic timeout.
- Normal Boring Notch content returns after the preview.
- An absent receiver restores the FihFlow panel.
- Quitting the receiver during a preview restores the panel; restarting the
  receiver during that preview removes the panel and resumes notch presentation.

Still pending before merge: real dictation/stop/cancel/error paths, fullscreen
and display changes, and coexistence with active music/system HUDs. Synthetic
preview does not verify microphone capture, permissions, or transcription.

## Rollback and license

Turn the FihFlow integration off, quit the custom Boring Notch build, restore the
saved app, and relaunch it. The source is reproducible from the pinned upstream
checkout plus this adapter. Boring Notch retains its upstream GPL-3.0 license;
any redistribution of a combined build must include the corresponding source
and license. No Boring Notch binary is committed to this repository.
