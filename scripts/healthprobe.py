#!/usr/bin/env python3
"""Health probe that exercises the INFERENCE path.

Why this exists
---------------
On 2026-09-12 Infinity stopped serving embeddings on ddai3: every request to
`/embeddings` timed out, through the gateway and directly. Docker reported the
container **healthy** for the whole episode, because the probe was
`GET /health` — served by the HTTP layer, which was fine. The thing that was
broken was the only thing the probe did not touch.

Two separate gaps, and fixing one without the other fixes nothing:

1. A liveness probe cannot see a hung inference path. So this probe sends a
   real request — one short embedding, or a short completion — and checks
   the response has the shape the contract promises.

2. `restart: unless-stopped` does NOT act on health. Docker's restart policy
   fires when the process EXITS; an unhealthy container is simply labelled and
   left running. Detection alone therefore recovers nothing — see
   scripts/watchdog.sh, which is the half that acts, and runs on the HOST.

WHY THE RESET IS NOT HERE. The first version of this script killed PID 1 after
N consecutive failures, so the restart policy would replace the container. It
was tested against a real hang and DID NOT WORK: in the Infinity container PID
1 *is* the engine, and the kernel discards default-action signals sent to PID 1
from inside its own namespace unless the process installed a handler — and a
process whose event loop is wedged cannot run a handler anyway. The probe
reported "8 consecutive failures — killing PID 1" and the container went on
running, untouched, for another seven minutes. A watchdog that cannot fire at
the one failure it exists for is worse than none, because it reads like cover.

An engine under load is slow, not hung, so keep --timeout generous: this probe
only reports, and the restart decision (with its own consecutive-failure
threshold) belongs to the watchdog.

Exit 0 = serving. Exit 1 = not serving; Docker marks the container unhealthy
after its own `retries`, which is what the host watchdog keys on.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import socket
import sys
import time
import urllib.error
import urllib.request


def _probe(url: str, payload: dict, timeout: float, expect: str) -> tuple[bool, str]:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status != 200:
                return False, f"HTTP {r.status}"
            body = json.load(r)
    except urllib.error.HTTPError as e:      # a 4xx/5xx IS an answer: the
        return False, f"HTTP {e.code}"        # engine is up but refusing
    except Exception as e:                    # noqa: BLE001 — timeout, reset, DNS
        if _is_timeout(e):
            return False, f"timeout: {e}"
        return False, f"{type(e).__name__}: {e}"
    if not isinstance(body, dict) or not isinstance(body.get(expect), list) or not body[expect]:
        return False, f"200 but no {expect!r} in response"
    if expect == "data":
        inputs = payload.get("input", [])
        count = len(inputs) if isinstance(inputs, list) else 1
        if len(body[expect]) != count:
            return False, "embedding count mismatch"
        for item in body[expect]:
            vector = item.get("embedding") if isinstance(item, dict) else None
            if not isinstance(vector, list) or not vector:
                return False, "empty embedding"
            if "bge-m3" in str(payload.get("model", "")).lower() and len(vector) != 1024:
                return False, "BGE-M3 embedding dimension must be 1024"
            if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in vector):
                return False, "invalid embedding values"
            if not any(v != 0 for v in vector):
                return False, "zero embedding"
    elif expect == "choices":
        choice = body[expect][0]
        message = choice.get("message", {}) if isinstance(choice, dict) else {}
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, str) or not content.strip():
            return False, "no usable chat content"
    return True, "ok"


# ── Busy is not hung (2026-10-10, ddai3) ─────────────────────────────────────
# ~20 long prompts in flight made the 8-token probe queue past its timeout for
# five minutes; Docker marked vLLM unhealthy and the watchdog restarted a
# healthy engine, failing every LLM call while it reloaded. On a TIMEOUT only,
# the probe now reads the engine's own /metrics twice: requests running and
# token counters advancing = busy, healthy. A wedged API server cannot answer
# /metrics and a hung engine core advances nothing, so a real hang still fails.
# Spec: project-deepdarshak/.claude/specs/completed/2026-10-10-gpu-watchdog-recovers-a-starved-vllm.md (REQ-WD-02)
METRICS_TIMEOUT = 1.5
PROGRESS_WAIT = 1.5
_COUNTER = re.compile(r"^(vllm:(?:num_requests_running|prompt_tokens_total|generation_tokens_total))\{[^}]*\}\s+([0-9.eE+-]+)$")


def _is_timeout(e: BaseException) -> bool:
    if isinstance(e, (socket.timeout, TimeoutError)):
        return True
    reason = getattr(e, "reason", None)
    return isinstance(reason, (socket.timeout, TimeoutError))


def chat_budget(timeout: float) -> float:
    """The completion's share of the probe's time; the rest is the busy check."""
    return max(5.0, timeout - 2 * METRICS_TIMEOUT - PROGRESS_WAIT - 0.5)


def _metrics(base: str) -> dict[str, float] | None:
    try:
        with urllib.request.urlopen(f"{base}/metrics", timeout=METRICS_TIMEOUT) as r:
            text = r.read().decode("utf-8", "replace")
    except Exception:  # noqa: BLE001 — unreachable metrics is no evidence of progress
        return None
    out: dict[str, float] = {}
    for line in text.splitlines():
        m = _COUNTER.match(line.strip())
        if m:
            out[m.group(1)] = out.get(m.group(1), 0.0) + float(m.group(2))
    return out


def _progressing(url: str) -> tuple[bool, str]:
    base = url.split("/v1/", 1)[0]
    first = _metrics(base)
    time.sleep(PROGRESS_WAIT)
    second = _metrics(base)
    if not first or not second:
        return False, "metrics unreachable"
    running = second.get("vllm:num_requests_running", 0.0)
    moved = sum(second.get(k, 0.0) - first.get(k, 0.0)
                for k in ("vllm:prompt_tokens_total", "vllm:generation_tokens_total"))
    if running > 0 and moved > 0:
        return True, f"busy: {running:.0f} running, {moved:.0f} tokens in {PROGRESS_WAIT}s"
    return False, f"no progress ({running:.0f} running, {moved:.0f} tokens)"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--kind", choices=("embeddings", "chat"), required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--timeout", type=float, default=20.0)
    # Accepted and ignored, so an older compose file keeps working after an
    # image update rather than failing every probe on an unknown argument.
    p.add_argument("--threshold", type=int, default=0, help=argparse.SUPPRESS)
    p.add_argument("--state", default="", help=argparse.SUPPRESS)
    args = p.parse_args()

    if args.kind == "embeddings":
        payload, expect = {"model": args.model, "input": ["health probe"]}, "data"
    else:
        payload = {"model": args.model, "max_tokens": 8,
                   "chat_template_kwargs": {"enable_thinking": False},
                   "messages": [{"role": "user", "content": "ping"}]}
        expect = "choices"

    timeout = chat_budget(args.timeout) if args.kind == "chat" else args.timeout
    ok, why = _probe(args.url, payload, timeout, expect)
    if ok:
        return 0
    if args.kind == "chat" and why.startswith("timeout"):
        busy, detail = _progressing(args.url)
        if busy:
            print(f"healthprobe: slow, not hung — {detail}", file=sys.stderr)
            return 0
        why = f"{why}; {detail}"
    print(f"healthprobe: {why}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
