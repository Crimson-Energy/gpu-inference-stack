import importlib.util
import io
import json
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("rerank_healthprobe", Path(__file__).resolve().parents[1] / "healthprobe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def test_reranker_probe_requires_a_finite_scored_result():
    for body, expected in [({"results": [{"index": 0, "relevance_score": .8}]}, True),
                           ({"results": []}, False), ({"results": [{"index": 1, "relevance_score": .8}]}, False)]:
        response = io.BytesIO(json.dumps(body).encode())
        response.status = 200
        with patch.object(probe.urllib.request, "urlopen", return_value=response):
            ok, _ = probe._probe("http://test/rerank", {"model": "m", "documents": ["x"]}, 1, "results")
            assert ok is expected
