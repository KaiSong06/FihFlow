# Local Cohere transcription with OpenAI cleanup

FihFlow runs Cohere Transcribe on your Apple Silicon Mac through MLX Audio.
It reuses Superwhisper's downloaded 4-bit MLX checkpoint without modifying or
copying the model. The app sends the resulting text to OpenAI for cleanup.
The preset uses `gpt-4.1-mini`; change the cleanup model in Provider Settings.

## Setup

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) if needed,
then run from the repository:

```sh
bash scripts/setup-local-cohere.sh
make APP_NAME=FihFlow BUNDLE_ID=com.kaisong.fihflow CODESIGN_IDENTITY=-
open build/FihFlow.app
```

The installer creates a separate Python 3.12 runtime under
`~/Library/Application Support/FihFlow/runtime` and installs MLX Audio 0.6.2.
Installation downloads runtime packages, but does not download model weights.
The native app continues to build with `swiftc` and Make.

1. In onboarding, choose **Use Local Cohere + OpenAI**. For an existing setup,
   find the same button in Settings → Advanced Provider Settings.
2. Enter an OpenAI API key in the app's secure field and continue/save.
   The cleanup base URL should be `https://api.openai.com/v1`.
3. In Provider Settings, check the model folder and Python runtime. The default
   model folder is
   `~/Library/Application Support/superwhisper/models/cohere-transcribe/cohere-transcribe-q4`.
   Use **Choose…** if your model is elsewhere. A complete single-file MLX Cohere
   checkpoint is required; GGUF, Core ML and ONNX formats are not supported.
4. Grant Microphone and Accessibility permissions when you are ready to dictate.
   Screen Recording is unnecessary with app context disabled.

The preset selects English. Cohere requires an explicit language; the existing
Auto-detect choice also uses English in local mode. Select another supported
language before dictating it. Unsupported languages produce an error.

## Behavior and privacy

- Audio passes to a local helper through private process pipes and local file
  paths. No listening server or cloud transcription fallback is used.
- The helper loads the model on the first request and keeps it resident until
  the app quits, a request is cancelled, or an error requires a restart.
- Loading verifies the complete weight inventory. Swift-style checkpoint names
  are mapped in memory; the original download is unchanged. A partial load is
  rejected rather than running with uninitialized weights.
- The helper runs with Hugging Face offline mode and telemetry disabled. It
  receives no provider API keys and emits no audio/transcript diagnostic logs.
- Local transcription defaults to a 120-second timeout, including cold loading.
  The existing `transcription_timeout_seconds` preference can override it.
- Realtime cloud streaming is bypassed while local Cohere is selected.
- The preset disables app-context collection and screenshot uploads. Cleanup
  still sends transcript text, configured vocabulary/custom instructions, and
  selected text for explicitly used Edit Mode to the configured cleanup provider.
- Existing FreeFlow local audio/history storage behavior is unchanged. This
  feature does not make the entire dictation pipeline offline while OpenAI is
  configured for cleanup.

Cloud transcription remains available by turning off **Use local Cohere
transcription** and configuring a cloud transcription model and endpoint.
A future local cleanup server can use the existing OpenAI-compatible base URL
and model settings.

## Verification

```sh
make check
git diff --check
```

The checks use synthetic worker fixtures, with no model download or provider
calls. They cover worker reuse, cancellation/restart, missing-runtime errors,
weight-name conversion, safe error responses, and cleanup-only key validation.
An actual model smoke test should use generated speech rather than private
recordings. Microphone capture, shortcuts, insertion, and paid OpenAI cleanup
must also be checked manually before merging.

References: [MLX Audio](https://github.com/Blaizzy/mlx-audio),
[OpenAI GPT-4.1 mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini).
