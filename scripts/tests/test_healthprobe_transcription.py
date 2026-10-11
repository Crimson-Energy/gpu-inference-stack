"""The stt service is probed through a real transcription (healthprobe.py).

A speech server whose HTTP layer answers /health while the Whisper model is
wedged would look healthy to a liveness probe, the trap this probe exists for.
So `--kind transcription` posts a generated one-second silent WAV to
/v1/audio/transcriptions and requires a JSON `text` string back; silence
transcribes to "", which is still an answer.

Spec: project-deepdarshak/.claude/specs/2026-10-11-voice-questions-for-the-advisor.md (REQ-STT-01)
"""
import importlib.util
import io
import json
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("healthprobe", ROOT / "scripts/healthprobe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

URL = "http://localhost:8000/v1/audio/transcriptions"


def _response(body):
    r = io.BytesIO(json.dumps(body).encode())
    r.status = 200
    return r


class TranscriptionProbe(unittest.TestCase):
    def run_main(self, answer):
        sent = []

        def urlopen(req, timeout=None):
            sent.append(req)
            if isinstance(answer, Exception):
                raise answer
            return answer

        argv = ["healthprobe.py", "--url", URL, "--kind", "transcription",
                "--model", "whisper-x", "--timeout", "20"]
        with patch.object(probe.urllib.request, "urlopen", side_effect=urlopen), \
                patch("sys.argv", argv):
            return probe.main(), sent

    def test_silence_transcribed_to_empty_text_is_serving(self):
        code, _ = self.run_main(_response({"text": ""}))
        self.assertEqual(code, 0)

    def test_the_request_is_multipart_with_a_wav_file_and_the_model(self):
        _, sent = self.run_main(_response({"text": ""}))
        req = sent[0]
        self.assertTrue(req.get_header("Content-type").startswith("multipart/form-data; boundary="))
        body = req.data
        self.assertIn(b'name="model"\r\n\r\nwhisper-x', body)
        self.assertIn(b'name="file"; filename="probe.wav"', body)
        self.assertIn(b"RIFF", body)
        self.assertIn(b"WAVE", body)

    def test_200_without_a_text_field_is_not_serving(self):
        code, _ = self.run_main(_response({"segments": []}))
        self.assertEqual(code, 1)

    def test_an_http_error_is_not_serving(self):
        err = urllib.error.HTTPError(URL, 500, "boom", {}, None)
        code, _ = self.run_main(err)
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
