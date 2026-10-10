"""A busy engine is not a hung one (healthprobe.py).

On 2026-10-10 (ddai3) vLLM served ~20 long prompts at once; the probe's short
completion queued past its 20 s timeout for five minutes, Docker marked the
container unhealthy and the watchdog restarted a healthy engine — every LLM
call on the box failed while it reloaded. A probe that times out now asks the
engine's own /metrics whether it is making progress.

Spec: project-deepdarshak/.claude/specs/completed/2026-10-10-gpu-watchdog-recovers-a-starved-vllm.md (REQ-WD-02)
"""
import importlib.util
import io
import socket
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("healthprobe", ROOT / "scripts/healthprobe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def _metrics(running, prompt, generation):
    text = (f'vllm:num_requests_running{{engine="0",model_name="m"}} {running}\n'
            f'vllm:prompt_tokens_total{{engine="0",model_name="m"}} {prompt}\n'
            f'vllm:generation_tokens_total{{engine="0",model_name="m"}} {generation}\n')
    r = io.BytesIO(text.encode())
    r.status = 200
    return r


class BusyIsNotHung(unittest.TestCase):
    def run_main(self, chat_error, metrics):
        """main() with the completion raising *chat_error* and /metrics answering *metrics* in turn."""
        reads = iter(metrics)

        def urlopen(req, timeout=None):
            url = req if isinstance(req, str) else req.full_url
            if url.endswith("/metrics"):
                item = next(reads)
                if isinstance(item, Exception):
                    raise item
                return item
            raise chat_error

        argv = ["healthprobe.py", "--url", "http://localhost:8000/v1/chat/completions",
                "--kind", "chat", "--model", "m", "--timeout", "20"]
        with patch.object(probe.urllib.request, "urlopen", side_effect=urlopen), \
                patch.object(probe.time, "sleep", lambda s: None), patch("sys.argv", argv):
            return probe.main()

    def test_a_timeout_while_tokens_flow_is_busy_not_hung(self):
        self.assertEqual(self.run_main(socket.timeout("timed out"),
                                       [_metrics(10, 1000, 500), _metrics(10, 1800, 540)]), 0)

    def test_a_timeout_with_no_progress_is_hung(self):
        self.assertEqual(self.run_main(socket.timeout("timed out"),
                                       [_metrics(10, 1000, 500), _metrics(10, 1000, 500)]), 1)

    def test_a_timeout_with_nothing_running_is_hung(self):
        self.assertEqual(self.run_main(socket.timeout("timed out"),
                                       [_metrics(0, 1000, 500), _metrics(0, 1000, 500)]), 1)

    def test_unreachable_metrics_is_hung(self):
        self.assertEqual(self.run_main(socket.timeout("timed out"),
                                       [OSError("connection refused"), OSError("refused")]), 1)

    def test_a_refused_connection_is_never_busy(self):
        # Only a timeout can mean "slow"; an engine that refuses is down.
        self.assertEqual(self.run_main(ConnectionRefusedError("refused"),
                                       [_metrics(10, 1000, 500), _metrics(10, 1800, 540)]), 1)

    def test_the_whole_probe_fits_the_docker_timeout(self):
        # Docker's healthcheck timeout is 25 s; completion + two metric reads must fit.
        self.assertLessEqual(probe.chat_budget(20.0) + 2 * probe.METRICS_TIMEOUT + probe.PROGRESS_WAIT, 20.0)


if __name__ == "__main__":
    unittest.main()
