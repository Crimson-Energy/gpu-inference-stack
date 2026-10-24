"""Stamp a vLLM scheduling priority on each request, by contract role.

WHY. Every chat role on a box — gpu/chat/interactive, /fast, /vision and
/bulk — is usually ONE vLLM instance, and vLLM serves first come, first
served. A consumer's bulk extraction burst (graph extraction runs dozens of
requests at once) therefore puts everyone's interactive chat at the back of
its queue, and the stack cannot tell them apart once they reach the engine.

vLLM's `--scheduling-policy priority` can: a lower `priority` is scheduled
first, and when KV cache runs short the highest number is preempted first
(vllm/v1/core/sched/scheduler.py). The role already says what a request is,
so this callback turns the role into the priority — consumers change nothing.

THREE TRAPS this avoids:
  - vLLM REJECTS a non-zero priority unless it runs the priority policy, so
    nothing is stamped unless VLLM_SCHEDULING_POLICY=priority — the same
    variable that starts the vLLM instances (check-contract-wiring.sh refuses
    a render where litellm's and theirs differ).
  - A TOP-LEVEL `priority` in a LiteLLM request routes it through LiteLLM's
    own beta request scheduler. So the value goes in `extra_body`, which
    LiteLLM passes to the engine untouched.
  - A role pointed at a PEER stack would deliver that body to the peer's
    LiteLLM — top level again. Only local vLLM backends (vllm*, vllm-new,
    vllm-router) are stamped; llama.cpp and Ollama have no such field.

Priorities (env, lower = sooner): ROLE_PRIORITY_INTERACTIVE / _FAST /
_VISION default 0, ROLE_PRIORITY_BULK default 10.
"""
from __future__ import annotations

import os
import re
from typing import Any, Optional
from urllib.parse import urlparse

from litellm.integrations.custom_logger import CustomLogger

_LOCAL_VLLM = re.compile(r"^vllm(\d*|-new|-router)$")


def _role_priorities() -> dict[str, int]:
    roles = {
        "gpu/chat/interactive": "ROLE_PRIORITY_INTERACTIVE",
        "gpu/chat/fast": "ROLE_PRIORITY_FAST",
        "gpu/chat/bulk": "ROLE_PRIORITY_BULK",
        os.environ.get("CONTRACT_VISION_ALIAS") or "gpu/chat/vision": "ROLE_PRIORITY_VISION",
    }
    defaults = {"ROLE_PRIORITY_BULK": 10}
    out = {}
    for alias, var in roles.items():
        try:
            out[alias] = int(os.environ.get(var, "") or defaults.get(var, 0))
        except ValueError:
            out[alias] = defaults.get(var, 0)
    return out


def _model_group(kwargs: dict) -> Optional[str]:
    for key in ("metadata", "litellm_metadata"):
        meta = kwargs.get(key)
        if isinstance(meta, dict) and meta.get("model_group"):
            return str(meta["model_group"])
    return None


def is_local_vllm(api_base: Any) -> bool:
    host = urlparse(str(api_base or "")).hostname or ""
    return bool(_LOCAL_VLLM.match(host))


def stamp(kwargs: dict) -> Optional[dict]:
    """kwargs with extra_body.priority set for this role, or None to leave it."""
    if os.environ.get("VLLM_SCHEDULING_POLICY", "").strip().lower() != "priority":
        return None
    priority = _role_priorities().get(_model_group(kwargs) or "")
    if priority is None or not is_local_vllm(kwargs.get("api_base")):
        return None
    extra = dict(kwargs.get("extra_body") or {})
    extra["priority"] = priority
    return {**kwargs, "extra_body": extra}


class RolePriority(CustomLogger):
    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        try:
            return stamp(kwargs)
        except Exception:  # noqa: BLE001 — a priority hint must never fail a request
            return None


role_priority = RolePriority()
