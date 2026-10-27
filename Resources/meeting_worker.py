"""Offline meeting diarization and ASR. Only progress/error codes reach stdout."""
import contextlib
import json
import os
from pathlib import Path
import sys
import wave


def name_speakers(segments, observations):
    votes = {}
    for segment in segments:
        if segment["speaker"] == "me":
            continue
        # An observation lasts at most 2.5 seconds; hidden/stale UI is not evidence.
        for observation in observations:
            overlap = max(0, min(segment["end"], observation["time"] + 2.5) - max(segment["start"], observation["time"]))
            if overlap:
                bucket = votes.setdefault(segment["speaker"], {})
                bucket[observation["name"]] = bucket.get(observation["name"], 0) + overlap
    names = {}
    for speaker, bucket in votes.items():
        ranked = sorted(bucket.items(), key=lambda item: -item[1])
        name, score = ranked[0]
        if score >= 2 and score / sum(bucket.values()) >= 0.75:
            names[speaker] = name
    # A shared name across voice clusters is ambiguous; ask the user to rename.
    return {speaker: name for speaker, name in names.items() if list(names.values()).count(name) == 1}


def split_turn(start, end, maximum=25):
    while start < end:
        stop = min(end, start + maximum)
        yield start, stop
        start = stop


def read_wave(path):
    import numpy as np
    with wave.open(str(path), "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 16000:
            raise ValueError("unsupported audio format")
        return np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768


def diarize(samples, model_dir):
    import sherpa_onnx
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(model_dir / "segmentation.onnx")),
            num_threads=2,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model_dir / "embedding.onnx"), num_threads=2),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=0.5),
        min_duration_on=0.3, min_duration_off=0.5,
    )
    if not config.validate():
        raise ValueError("missing diarization models")
    engine = sherpa_onnx.OfflineSpeakerDiarization(config)
    return engine.process(samples).sort_by_start_time()


def process(request, progress):
    from local_cohere_worker import load_local_model
    import numpy as np
    folder = Path(request["directory"])
    model_dir = Path(request["speakerModels"])
    progress("Separating meeting speakers")
    # Process each track separately to keep microphone speech independent of remote voices.
    turns = []
    for track in ["system", "microphone"]:
        samples = read_wave(folder / (track + ".wav"))
        if len(samples) and float(np.max(np.abs(samples))) > 0.001:
            for turn in diarize(samples, model_dir):
                speaker = "me" if track == "microphone" else f"remote-{turn.speaker}"
                for start, end in split_turn(turn.start, turn.end):
                    turns.append({"start": start, "end": end, "speaker": speaker, "track": track})
        del samples
    model = load_local_model(request["model"])
    language = request.get("language") or "en"
    if language not in model.config.supported_languages:
        raise ValueError("unsupported language")
    segments = []
    turns.sort(key=lambda item: (item["start"], item["speaker"]))
    for index, turn in enumerate(turns):
        progress(f"Transcribing turn {index + 1} of {len(turns)}")
        with wave.open(str(folder / (turn["track"] + ".wav")), "rb") as audio:
            # A little boundary padding preserves consonants around diarization cuts.
            start_frame = max(0, int((turn["start"] - 0.1) * 16000))
            end_frame = min(audio.getnframes(), int((turn["end"] + 0.1) * 16000))
            audio.setpos(start_frame)
            samples = np.frombuffer(audio.readframes(end_frame - start_frame), dtype="<i2").astype(np.float32) / 32768
        text = model.generate(samples, sample_rate=16000, language=language, max_tokens=1024, batch_size=1, verbose=False).text.strip()
        if text:
            segments.append({"id": f"s{index + 1}", "start": turn["start"], "end": turn["end"], "speaker": turn["speaker"], "text": text})
    names = name_speakers(segments, request.get("observations", []))
    speaker_ids = list(dict.fromkeys(segment["speaker"] for segment in segments))
    numbers = {speaker: index + 1 for index, speaker in enumerate(s for s in speaker_ids if s != "me")}
    speakers = [{"id": speaker, "name": "Me" if speaker == "me" else names.get(speaker, f"Speaker {numbers[speaker]}"), "source": "microphone" if speaker == "me" else ("meeting UI (suggested)" if speaker in names else "voice grouping")} for speaker in speaker_ids]
    output = folder / "transcript.json"
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps({"segments": segments, "speakers": speakers}, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(output)


def main():
    os.umask(0o077)
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    destination = sys.stdout
    def emit(value):
        destination.write(json.dumps(value) + "\n")
        destination.flush()
    try:
        request = json.loads(sys.stdin.readline())
        with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            process(request, lambda status: emit({"progress": status}))
        emit({"done": True})
    except Exception:
        emit({"error": "Local meeting transcription failed. Check the runtime, model files, language and available memory. Audio has been kept for retry."})
        raise SystemExit(1)


if __name__ == "__main__":
    main()
