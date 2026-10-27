"""Private stdin/stdout bridge. No HTTP server, model downloads or content logs."""

import contextlib
import json
import os
from pathlib import Path
import re
import sys


def python_weight_name(name):
    """Map the original Swift MLX Cohere checkpoint to mlx-audio's names."""
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower()
    name = re.sub(r"(pre_encode\.conv)([0-9]+)\.", r"\1.\2.", name)
    name = re.sub(r"\.layer_norm([123])\.", r".layer_norm_\1.", name)
    return name.replace("log_softmax.mlp_layer0.", "log_softmax.mlp.layer0.")


def load_local_model(model_path):
    import mlx.core as mx
    from mlx_audio.stt.models.cohere_asr.cohere_asr import Model
    from mlx_audio.stt.models.cohere_asr.config import ModelConfig
    from mlx_audio.utils import apply_quantization

    path = Path(model_path)
    config = json.loads((path / "config.json").read_text())
    if config.get("model_type") != "cohere_asr":
        raise ValueError("not a Cohere checkpoint")
    mx.set_cache_limit(256 * 1024 * 1024)
    weights = mx.load(str(path / "model.safetensors"))
    if "encoder.preEncode.conv0.weight" in weights:
        mapped = {}
        for name, value in weights.items():
            # Python computes this relative-position buffer itself.
            if name == "encoder.posEnc.pe":
                continue
            key = python_weight_name(name)
            if key in mapped:
                raise ValueError("duplicate weight name")
            mapped[key] = value
        weights = mapped
    model = Model(ModelConfig.from_dict(config))
    weights = model.sanitize(weights)
    apply_quantization(model, config, weights)
    # Never accept partially loaded weights: the default upstream loader is lenient.
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    return Model.post_load_hook(model, path)


def serve(model_path, source, destination, loader):
    model = None
    for line in source:
        try:
            request = json.loads(line)
            audio = Path(request["audio"])
            if not audio.is_file():
                raise ValueError("missing audio")
            language = request.get("language") or "en"
            if model is None:
                model = loader(str(model_path))
            if language not in model.config.supported_languages:
                response = {"error": "unsupported_language"}
            else:
                result = model.generate(
                    str(audio), language=language, max_tokens=1024,
                    batch_size=1, verbose=False,
                )
                response = {"text": result.text.strip()}
        except Exception:
            # Do not expose exception messages: they may contain user content.
            response = {"error": "transcription_failed"}
        destination.write(json.dumps(response, ensure_ascii=False) + "\n")
        destination.flush()


def main():
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    model_path = Path(sys.argv[1]).expanduser().resolve(strict=True)
    # A local directory is mandatory; a typo must never trigger a Hub download.
    if not model_path.is_dir() or not (model_path / "model.safetensors").is_file():
        raise SystemExit(1)
    destination = sys.stdout
    with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        serve(model_path, sys.stdin, destination, load_local_model)


if __name__ == "__main__":
    main()
