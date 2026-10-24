"""Load-aware capacity per contract role (scripts/capacity.py).

vLLM queues rather than rejects, so a client can never discover "too many"
from an error — only from everyone's latency climbing. /capacity turns the
engines' own metrics into a number a client can act on. These tests pin the
advice: it fills an idle box, backs off a busy one, stops at a queue, sizes
for long requests by KV cache, and never offers room on a dead engine.
"""
import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("capacity", ROOT / "scripts/capacity.py")
cap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cap)


def vllm_metrics(running=0, waiting=0, kv=0.0, kv_tokens=200000, awake=1.0, gen=1000, e2e_sum=10, e2e_count=5):
    return f"""# HELP vllm:num_requests_running x
vllm:num_requests_running{{engine="0",model_name="m"}} {running}
vllm:num_requests_waiting{{engine="0",model_name="m"}} {waiting}
vllm:kv_cache_usage_perc{{engine="0",model_name="m"}} {kv}
vllm:cache_config_info{{block_size="16",kv_cache_size_tokens="{kv_tokens}",kv_cache_max_concurrency="6.1"}} 1.0
vllm:engine_sleep_state{{engine="0",sleep_state="awake"}} {awake}
vllm:generation_tokens_total{{engine="0",model_name="m"}} {gen}
vllm:prompt_tokens_total{{engine="0",model_name="m"}} {gen * 3}
vllm:e2e_request_latency_seconds_sum{{engine="0",model_name="m"}} {e2e_sum}
vllm:e2e_request_latency_seconds_count{{engine="0",model_name="m"}} {e2e_count}
"""


class VllmAdvice(unittest.TestCase):
    def advice(self, tokens=None, seqs="64", **kw):
        with patch.dict(os.environ, {"CAPACITY_MAX_NUM_SEQS": seqs}), \
                patch.object(cap, "http_get", return_value=(200, vllm_metrics(**kw))):
            facts = cap.read_vllm("http://vllm:8000")
        return cap.vllm_advice(facts, {"mean_latency_s": 20.0}, tokens)

    def test_idle_engine_offers_every_free_slot(self):
        a = self.advice()
        self.assertEqual(a["state"], "idle")
        self.assertEqual(a["free_slots"], 64)
        self.assertEqual(a["recommended_concurrency"], 64)

    def test_busy_engine_hands_out_half_the_room(self):
        a = self.advice(running=44)
        self.assertEqual(a["state"], "busy")
        self.assertEqual(a["free_slots"], 20)
        self.assertEqual(a["recommended_concurrency"], 10)

    def test_a_queue_means_send_nothing_and_says_when_to_look_again(self):
        a = self.advice(running=64, waiting=8)
        self.assertEqual(a["state"], "saturated")
        self.assertEqual(a["recommended_concurrency"], 0)
        self.assertGreaterEqual(a["retry_after_s"], 1.0)

    def test_kv_cache_bounds_long_requests_even_with_free_slots(self):
        # 64 slots are free, but 200k tokens of KV (95% usable) fit only 6
        # requests of 30k tokens each.
        a = self.advice(tokens=30000)
        self.assertEqual(a["free_slots"], 6)
        self.assertEqual(a["recommended_concurrency"], 6)

    def test_a_full_kv_cache_is_saturated_whatever_the_slots_say(self):
        a = self.advice(running=4, kv=0.93)
        self.assertEqual(a["state"], "saturated")
        self.assertEqual(a["recommended_concurrency"], 0)

    def test_a_sleeping_engine_is_down(self):
        with patch.dict(os.environ, {"CAPACITY_MAX_NUM_SEQS": "64"}), \
                patch.object(cap, "http_get", return_value=(200, vllm_metrics(awake=0.0))):
            self.assertFalse(cap.read_vllm("http://vllm:8000")["healthy"])

    def test_an_unreachable_engine_is_down(self):
        with patch.object(cap, "http_get", return_value=(0, "")):
            self.assertFalse(cap.read_vllm("http://vllm:8000")["healthy"])


class Report(unittest.TestCase):
    ENV = {
        "CONTRACT_BULK_API_BASE": "http://vllm:8000/v1", "CONTRACT_BULK_MODEL": "openai/qwen3.6",
        "CONTRACT_INTERACTIVE_API_BASE": "http://vllm:8000/v1", "CONTRACT_INTERACTIVE_MODEL": "openai/qwen3.6",
        "CONTRACT_FAST_API_BASE": "http://vllm:8000/v1", "CONTRACT_FAST_MODEL": "openai/qwen3.6",
        "CONTRACT_EMBED_ALIAS": "gpu/embed/bge-m3", "CONTRACT_EMBED_API_BASE": "http://infinity:7997",
        "CONTRACT_VISION_ALIAS": "unserved/vision", "CONTRACT_VISION_API_BASE": "http://ollama:11434",
        "CAPACITY_MAX_NUM_SEQS_VLLM": "32",
    }

    def fake_get(self, url, key=None, timeout=None):
        self.calls.append(url)
        if url.endswith("/metrics") and "vllm" in url:
            return 200, vllm_metrics(running=8)
        if url.endswith("/models"):
            return 200, '{"data":[{"id":"BAAI/bge-m3","stats":{"queue_fraction":0.0,"queue_absolute":0,"results_pending":2,"batch_size":32}}]}'
        return 0, ""

    def report(self):
        self.calls = []
        with patch.dict(os.environ, self.ENV, clear=False), patch.object(cap, "http_get", side_effect=self.fake_get):
            p = cap.Poller()
            p.poll_once()
            return p.report()

    def test_reports_every_served_role_and_skips_unserved_ones(self):
        roles = self.report()["roles"]
        self.assertIn("gpu/chat/bulk", roles)
        self.assertIn("gpu/embed/bge-m3", roles)
        self.assertNotIn("unserved/vision", roles)

    def test_three_chat_roles_on_one_engine_cost_one_scrape(self):
        self.report()
        self.assertEqual(sum(1 for u in self.calls if u == "http://vllm:8000/metrics"), 1)

    def test_per_instance_ceiling_comes_from_the_instance_variable(self):
        self.assertEqual(self.report()["roles"]["gpu/chat/bulk"]["max_concurrency"], 32)

    def test_prometheus_exposition_carries_every_role(self):
        text = cap.to_prometheus(self.report())
        self.assertIn('gis_capacity_recommended_concurrency{role="gpu/chat/bulk",backend="vllm"}', text)
        self.assertIn('gis_capacity_state{role="gpu/embed/bge-m3",backend="infinity"}', text)


class Rates(unittest.TestCase):
    def test_rates_come_from_counter_deltas_and_ignore_a_reset(self):
        p = cap.Poller()
        p.history["r"] = [(0.0, {"generation_tokens": 1000, "e2e_sum": 10, "e2e_count": 5}),
                          (10.0, {"generation_tokens": 3000, "e2e_sum": 40, "e2e_count": 15})]
        r = p.rates("r")
        self.assertEqual(r["generation_tokens_per_s"], 200.0)
        self.assertEqual(r["mean_latency_s"], 3.0)
        p.history["r"][-1] = (10.0, {"generation_tokens": 10, "e2e_sum": 1, "e2e_count": 1})
        self.assertIsNone(p.rates("r")["generation_tokens_per_s"])


class Backends(unittest.TestCase):
    def test_kind_follows_the_service_name(self):
        self.assertEqual(cap.backend_kind("http://vllm:8000/v1"), "vllm")
        self.assertEqual(cap.backend_kind("http://vllm2:8000/v1"), "vllm")
        self.assertEqual(cap.backend_kind("http://vllm-router:8080/v1"), "vllm-router")
        self.assertEqual(cap.backend_kind("http://infinity:7997"), "infinity")
        self.assertEqual(cap.backend_kind("http://100.117.227.40:8080/v1"), "remote")

    def test_a_peer_role_is_answered_by_the_peers_own_capacity(self):
        body = '{"roles":{"gpu/chat/bulk":{"state":"busy","recommended_concurrency":3}}}'
        with patch.object(cap, "http_get", return_value=(200, body)) as get:
            f = cap.read_remote("http://10.0.0.5:8080/v1", "gpu/chat/bulk", "sk-peer")
        get.assert_called_once_with("http://10.0.0.5:8080/capacity/gpu/chat/bulk", key="sk-peer")
        self.assertEqual(f["remote"]["recommended_concurrency"], 3)


if __name__ == "__main__":
    unittest.main()
