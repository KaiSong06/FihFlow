import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location(
    "worker", Path(__file__).resolve().parents[1] / "Resources/local_cohere_worker.py"
)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def test_swift_weight_mapping(self):
        cases = {
            "encoder.preEncode.conv0.weight": "encoder.pre_encode.conv.0.weight",
            "encoder.layers.0.feedForward1.linear1.scales": "encoder.layers.0.feed_forward1.linear1.scales",
            "encoder.layers.0.selfAttn.posBiasU": "encoder.layers.0.self_attn.pos_bias_u",
            "transfDecoder.decoder.layers.1.layerNorm3.weight": "transf_decoder.decoder.layers.1.layer_norm_3.weight",
            "transfDecoder.embedding.positionEmbedding.posEnc": "transf_decoder.embedding.position_embedding.pos_enc",
            "logSoftmax.mlpLayer0.biases": "log_softmax.mlp.layer0.biases",
            "encoderDecoderProj.weight": "encoder_decoder_proj.weight",
        }
        for source, expected in cases.items():
            self.assertEqual(worker.python_weight_name(source), expected)

    def test_reuse_language_and_safe_failure(self):
        loads, calls = [], []

        def generate(audio, **kwargs):
            calls.append(kwargs)
            if len(calls) == 2:
                raise RuntimeError("SYNTHETIC_PRIVATE_CONTENT")
            return SimpleNamespace(text="  Bonjour, le monde.  ")

        def load(path):
            loads.append(path)
            return SimpleNamespace(config=SimpleNamespace(supported_languages=["en", "fr"]), generate=generate)

        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / "synthetic.wav"
            audio.touch()
            requests = [
                {"audio": str(audio), "language": "fr"},
                {"audio": str(audio), "language": "unsupported"},
                {"audio": str(audio)},
                {"audio": str(audio)},
                {"audio": str(audio.parent / "missing.wav")},
            ]
            source = io.StringIO("\n".join(json.dumps(r) for r in requests))
            output = io.StringIO()
            worker.serve(Path(directory), source, output, load)
            results = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(len(loads), 1)
            self.assertEqual(calls[0]["language"], "fr")
            self.assertEqual(calls[1]["language"], "en")
            self.assertEqual(results, [
                {"text": "Bonjour, le monde."}, {"error": "unsupported_language"},
                {"error": "transcription_failed"}, {"text": "Bonjour, le monde."},
                {"error": "transcription_failed"},
            ])
            self.assertNotIn("SYNTHETIC_PRIVATE_CONTENT", output.getvalue())


if __name__ == "__main__":
    unittest.main()
