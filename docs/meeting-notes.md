# Meeting notes

FihFlow can record a meeting's system audio and your microphone, transcribe
both locally, group remote speakers, and use the existing cleanup model for
notes. It requires **Apple Silicon and macOS 15 or later**. Dictation still
works on the app's existing macOS baseline.

## Setup and use

```sh
bash scripts/setup-meeting-models.sh
make APP_NAME=FihFlow BUNDLE_ID=com.kaisong.fihflow CODESIGN_IDENTITY=-
open build/FihFlow.app
```

The installer adds Sherpa ONNX 2.0.1 to the existing local Cohere runtime and
downloads the Pyannote segmentation and 3D-Speaker embedding models from
Sherpa's official releases (about 47 MB of downloads). It does not send audio
anywhere. Inference uses the already installed local Cohere model and offline
speaker models. No new Swift package or Xcode project is needed.

1. Open **Meeting Notes…** from the menu bar and open **Meeting settings**.
2. Use the explicit permission buttons to allow Microphone and macOS
   Screen & System Audio Recording. Accessibility is needed for detection and
   name suggestions. The app does not request these permissions just by opening
   Meeting Notes. A macOS permission change may require relaunching the app.
3. Enter the names people use for you, separated by commas. Microphone speech
   is always identified as `Me`; your aliases help resolve assignments addressed
   to you by name.
4. Enable **Detect meetings and suggest recording**. Detection is off initially;
   once enabled it asks before recording. **Automatically record detected
   meetings** is a separate, explicit opt-in.
5. Choose **Record meeting** on a detected call, or **Record system + mic**
   for any app. Detected capture includes the selected app's audio; browser
   capture can include other tabs. Manual capture includes all system audio
   except FihFlow itself. The microphone is the macOS default input.
6. Use headphones to avoid remote speech being captured again on the mic.
   The menu icon and Meeting Notes window show recording status. Recording
   continues until **Finish & create notes**, even if call detection disappears.
7. Review the transcript and speaker names. The default notes contain a summary,
   decisions, and **only your action items**. Each action has expandable source
   lines. Choose a participant and **Generate action items** to request theirs.
   Renaming a speaker should be followed by regenerating affected notes.

Provider Settings supplies the API key, base URL, and cleanup model. The local
Cohere + OpenAI preset uses `gpt-4.1-mini`. Meeting notes require an HTTPS
Chat Completions provider with strict JSON-schema structured outputs. A missing
key or rejected request leaves the transcript available for retry. No API key
is passed to either local worker.

## Detection and speaker limitations

Detection checks known Google Meet, Zoom, Teams, Webex, Slack, and FaceTime
applications/browser origins for active-call controls. It does not treat an
open app or pre-join page as a meeting. It reads a bounded Accessibility tree,
not screenshots. Browser and app versions, hidden tabs, localized controls,
or incomplete accessibility support can prevent detection. Use manual recording
when needed. Actual app compatibility must be verified on the installed versions.

Remote speaker IDs come from local voice clustering. Names are suggestions
only when an explicit accessible speaking indicator overlaps that voice's turns
consistently. Mere participant lists or tile positions are not name evidence.
Unknown or ambiguous speakers remain `Speaker N`; names can be edited. Video
tile highlighting without accessible text cannot currently supply names.

The microphone track is assumed to be one person: you. Shared-room microphones,
speakerphone echo, overlapping voices, similar voices, and noisy audio can produce
incorrect or duplicated attribution. Voice grouping is not identity verification.
The transcript appears after finishing, not live. Long turns are split for ASR;
overlapping speakers are not isolated into separate clean waveforms.

## Storage, recovery, and summaries

Two aligned 16 kHz mono PCM tracks stream to a private local meeting directory
under the app's Application Support folder. Gaps are preserved as silence, and
overlapping samples are trimmed to keep timestamps aligned. Audio uses about
230 MB per hour for both tracks together. Diarization reads one full track into
memory at a time (about 230 MB per hour as float32, plus model working memory).
Recording stops at 12 hours. Sleeping, device changes, or capture errors may
leave gaps; a stopped/failed capture retains the recorded portion and shows a
warning where the API reports an error.

Audio is deleted after a successful nonempty transcript unless **Keep audio**
was selected before recording. Audio is retained on transcription failure for
retry. Transcripts, observations, names, notes, and explicitly requested actions
remain local until **Delete**. Files use owner-only permissions. Interrupted
sessions are listed on restart; WAV recovery depends on how cleanly capture
closed. Metadata is checkpointed every 15 seconds. No meeting telemetry or
content logging is added.

Finishing sends transcript text, speaker names, and your aliases to your
configured provider for summarization. Audio and screenshots are not sent.
All transcript chunks are processed, including short overlaps for conversational
context; their summaries are reduced recursively. Default action extraction
requests only `me`, and output is filtered to that owner with valid source IDs.
Other participants' actions require an explicit request. Transcripts and model
responses are untrusted data; generated assignments still need human review.
Exports contain the summary, decisions, your actions, any requested participant
actions, and the full transcript.

## Validation and manual test before merge

`make check` covers detection rules, active-call false positives, ambiguous
speaker names, timeline alignment, storage permissions and recovery, chunk
coverage, owner/evidence filtering, requested participant actions, and provider
failures using synthetic data and mocked transport. The actual offline worker
was also exercised with two synthetic macOS speech voices, one on each track.
Native PCM tests verify conversion from 48 kHz stereo to 16 kHz mono, silent
gaps and duplicate callbacks; worker tests cover cancellation and retry.
An isolated native UI harness with invented meeting data verified transcript
tabs, action evidence, editable names, settings, and missing-key recovery.
No live provider requests or real meeting recordings are used by tests.

Manual checks still required on permission-enabled machines:

- Join and leave a test call in installed Meet/Zoom/Teams versions; verify a
  pre-join screen does not trigger, the prompt appears, Ignore suppresses it,
  and names are used only with a real speaking indicator. Check background tabs
  and native apps; confirm manual fallback when controls are unavailable.
- Record alternating and overlapping speakers with headphones. Verify both
  sources, microphone selection, timestamps, long pauses, a device change,
  and system audio capture scope. Check permission denial/revocation and sleep.
- Finish and verify a full transcript, edit names, enter your aliases, generate
  notes with the configured OpenAI model, then explicitly request another
  participant's actions. Review evidence, ambiguous assignments, and long calls.
- Exercise cancel/retry, restart recovery, deletion, export, missing API key,
  network failure, and insufficient disk space. Verify dictation is blocked
  during a meeting and works again afterward. Quit must require Finish or Cancel
  while busy. Confirm both audio files are removed under the default retention.

References: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit),
[Sherpa diarization example](https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/offline-speaker-diarization.py),
[OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs).
