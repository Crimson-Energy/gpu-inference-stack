"""Per-role vLLM priority (config/litellm/role_priority.py).

Every chat role usually shares one vLLM, which serves first come first served,
so a bulk burst queues interactive chat. The callback turns the role into
vLLM's request priority. These tests pin its three traps: nothing is stamped
unless vLLM runs the priority policy (it rejects a non-zero priority
otherwise), the value goes in extra_body (a top-level `priority` sends the
request through LiteLLM's own beta scheduler), and only local vLLM backends
are stamped (a peer stack's LiteLLM would read it at top level again).
"""
import importlib.util
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

# The callback imports litellm's CustomLogger; the tests do not need litellm.
_fake = types.ModuleType("litellm.integrations.custom_logger")
_fake.CustomLogger = type("CustomLogger", (), {})
sys.modules.setdefault("litellm", types.ModuleType("litellm"))
sys.modules.setdefault("litellm.integrations", types.ModuleType("litellm.integrations"))
sys.modules.setdefault("litellm.integrations.custom_logger", _fake)

spec = importlib.util.spec_from_file_location("role_priority", ROOT / "config/litellm/role_priority.py")
rp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rp)

ON = {"VLLM_SCHEDULING_POLICY": "priority"}


def call(group, base="http://vllm:8000/v1", **extra):
    return {"model": "openai/qwen", "api_base": base, "metadata": {"model_group": group}, **extra}


class RolePriority(unittest.TestCase):
    def test_bulk_yields_to_interactive(self):
        with patch.dict(os.environ, ON, clear=False):
            self.assertEqual(rp.stamp(call("gpu/chat/bulk"))["extra_body"], {"priority": 10})
            self.assertEqual(rp.stamp(call("gpu/chat/interactive"))["extra_body"], {"priority": 0})

    def test_it_goes_in_extra_body_never_top_level(self):
        with patch.dict(os.environ, ON, clear=False):
            out = rp.stamp(call("gpu/chat/bulk", extra_body={"chat_template_kwargs": {"enable_thinking": False}}))
        self.assertNotIn("priority", out)
        self.assertEqual(out["extra_body"], {"chat_template_kwargs": {"enable_thinking": False}, "priority": 10})

    def test_nothing_stamped_without_the_priority_policy(self):
        with patch.dict(os.environ, {"VLLM_SCHEDULING_POLICY": ""}, clear=False):
            self.assertNotIn("extra_body", rp.stamp(call("gpu/chat/bulk")))

    def test_only_local_vllm_backends(self):
        with patch.dict(os.environ, ON, clear=False):
            for base in ("http://vllm2:8000/v1", "http://vllm-new:8000/v1", "http://vllm-router:8080/v1"):
                self.assertIsNotNone(rp.stamp(call("gpu/chat/bulk", base)), base)
            for base in ("http://100.117.227.85:8080/v1", "http://llamacpp:8080/v1", "http://ollama:11434"):
                self.assertNotIn("extra_body", rp.stamp(call("gpu/chat/bulk", base)), base)

    def test_unknown_groups_get_no_stamp(self):
        with patch.dict(os.environ, ON, clear=False):
            self.assertNotIn("extra_body", rp.stamp(call("gpu/embed/bge-m3", "http://vllm:8000/v1")))
            self.assertNotIn("extra_body", rp.stamp({"api_base": "http://vllm:8000/v1"}))

    def test_a_client_cannot_set_its_own_priority(self):
        for env in (ON, {"VLLM_SCHEDULING_POLICY": ""}):
            with patch.dict(os.environ, env, clear=False):
                top = rp.stamp(call("gpu/chat/bulk", priority=-100))
                self.assertNotIn("priority", top)
                nested = rp.stamp(call("qwen3.6-new-direct", extra_body={"priority": -100, "top_k": 5}))
                self.assertEqual(nested["extra_body"], {"top_k": 5})
                peer = rp.stamp(call("gpu/chat/bulk", "http://100.117.227.85:8080/v1", priority=-100))
                self.assertNotIn("priority", peer)
        with patch.dict(os.environ, ON, clear=False):
            self.assertEqual(rp.stamp(call("gpu/chat/bulk", priority=-100))["extra_body"], {"priority": 10})

    def test_a_failing_stamp_still_strips_the_clients_priority(self):
        import asyncio
        with patch.object(rp, "stamp", side_effect=RuntimeError("boom")):
            out = asyncio.run(rp.role_priority.async_pre_call_deployment_hook(call("gpu/chat/bulk", priority=-100), None))
        self.assertNotIn("priority", out)

    def test_priorities_come_from_env(self):
        with patch.dict(os.environ, {**ON, "ROLE_PRIORITY_BULK": "50", "CONTRACT_VISION_ALIAS": "gpu/chat/vision"}):
            self.assertEqual(rp.stamp(call("gpu/chat/bulk"))["extra_body"]["priority"], 50)
            self.assertEqual(rp.stamp(call("gpu/chat/vision"))["extra_body"]["priority"], 0)


if __name__ == "__main__":
    unittest.main()
