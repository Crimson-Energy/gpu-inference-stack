#!/usr/bin/env python3
"""Live capacity of this box, per contract role — so a caller can size its load.

Why this exists
---------------
Every consumer of this stack decides on its own how many requests to put in
flight: ember's ingest runs N documents x M chunks at once, a dashboard fires a
burst of searches, a batch job picks a number and hopes. None of them can see
the engine, so they find the box's limit by hitting it. vLLM does not reject
when it is full — it QUEUES (measured on ddai4: 32 concurrent bulk requests and
a 154%-oversubscribed KV cache both returned 0 errors), so "too many" never
shows up as an error a client could back off from. It shows up as every
caller's latency climbing together, and as health probes timing out on a box
that is merely busy (the 2026-10-10 watchdog incident).

The engines already know their own load. This service reads it, maps it onto
the `gpu/<task>/<role>` contract a consumer actually addresses, and answers
one question: **how many more requests of my size can I send right now?**

    GET /capacity                     every role
    GET /capacity/gpu/chat/bulk       one role
    GET /capacity?tokens=6000         sized for requests of ~6000 tokens
                                      (prompt + max output)
    GET /metrics                      the same, as Prometheus gauges
    GET /health                       liveness

Consumers reach it THROUGH LiteLLM (`GET http://<box>:8080/capacity`, with
their usual virtual key) — config/litellm/config.yaml registers it as an
authenticated pass-through, so there is one base URL and one credential for
inference and for load, exactly as for every other call.

What each role reports
----------------------
Per role, from the engine that serves it:

    state                   idle | available | busy | saturated | down | unknown
    load                    0..1 — the larger of slot use and KV-cache use
    in_flight / waiting     requests running / queued in the engine now
    max_concurrency         the engine's own concurrency ceiling
    free_slots              how many more requests the engine can START now
    free_kv_tokens          KV-cache tokens free (vLLM) — what long requests need
    recommended_concurrency what ONE client should aim to keep in flight now
    retry_after_s           when saturated: a hint for when to look again
    rates                   tokens/s, mean latency, queue time over the window

`recommended_concurrency` is advice, recomputed every poll, and deliberately
conservative: when the box is busy it hands a client only half of the free
room so that two clients reading the same number do not both take all of it.
A client that re-reads it every few seconds and keeps at most that many
requests in flight will fill an idle box and back off from a busy one.

A role delegated to a PEER stack (its api_base is another host) is answered
by asking that peer's own /capacity for the same alias, with the role's key.

Everything is read-only and stdlib-only, like scripts/healthprobe.py: it runs
on the LiteLLM image already built for this stack, with no new image to pin.
"""
from __future__ import annotations

import json
import math
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POLL_SECONDS = float(os.environ.get("CAPACITY_POLL_SECONDS", "5"))
#: Rates (tokens/s, latency) are averaged over this many seconds of samples.
RATE_WINDOW_SECONDS = float(os.environ.get("CAPACITY_RATE_WINDOW_SECONDS", "60"))
TIMEOUT = float(os.environ.get("CAPACITY_HTTP_TIMEOUT", "3"))
DCGM_URL = os.environ.get("CAPACITY_DCGM_URL", "http://dcgm-exporter:9400/metrics")
PORT = int(os.environ.get("CAPACITY_PORT", "9097"))

#: Load thresholds for `state`. Busy hands out half the room; saturated none.
AVAILABLE_BELOW = 0.60
BUSY_BELOW = 0.90

#: KV-cache use at which vLLM starts preempting; the room left below it is
#: what new work can safely use.
KV_HEADROOM_CEILING = 0.95

# The contract roles, in the order a consumer reads them, and the env vars
# config/litellm/config.yaml binds each to. A role whose alias is outside the
# gpu/ namespace (unserved/…) is not reported: it is not part of the contract.
ROLES = [
    ("gpu/chat/interactive", None, "CONTRACT_INTERACTIVE"),
    ("gpu/chat/bulk", None, "CONTRACT_BULK"),
    ("gpu/chat/fast", None, "CONTRACT_FAST"),
    (None, "CONTRACT_VISION_ALIAS", "CONTRACT_VISION"),
    (None, "CONTRACT_EMBED_ALIAS", "CONTRACT_EMBED"),
    (None, "CONTRACT_RERANK_ALIAS", "CONTRACT_RERANK"),
    (None, "CONTRACT_STT_ALIAS", "CONTRACT_STT"),
]


# ---------------------------------------------------------------------------
# Prometheus text
# ---------------------------------------------------------------------------

_SAMPLE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})?\s+(\S+)')
_LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def parse_prometheus(text: str) -> list[tuple[str, dict, float]]:
    out = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        m = _SAMPLE.match(line)
        if not m:
            continue
        try:
            value = float(m.group(4))
        except ValueError:
            continue
        labels = dict(_LABEL.findall(m.group(3) or ""))
        out.append((m.group(1), labels, value))
    return out


def first(samples, name, **match) -> float | None:
    for n, labels, v in samples:
        if n == name and all(labels.get(k) == want for k, want in match.items()):
            return v
    return None


def total(samples, name) -> float | None:
    vals = [v for n, _, v in samples if n == name]
    return sum(vals) if vals else None


def labels_of(samples, name) -> dict:
    for n, labels, _ in samples:
        if n == name:
            return labels
    return {}


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def http_get(url: str, key: str | None = None, timeout: float = TIMEOUT) -> tuple[int, str]:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"} if key else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 — internal, configured URLs
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception:
        return 0, ""


def root_of(api_base: str) -> str:
    """`http://vllm:8000/v1` -> `http://vllm:8000` (the engine's own root)."""
    p = urllib.parse.urlsplit(api_base)
    return f"{p.scheme}://{p.netloc}"


def host_of(api_base: str) -> str:
    return (urllib.parse.urlsplit(api_base).hostname or "").lower()


# ---------------------------------------------------------------------------
# Which engine serves a role
# ---------------------------------------------------------------------------

def backend_kind(api_base: str) -> str:
    host = host_of(api_base)
    if host in ("vllm-router", "vllm-router-new"):
        return "vllm-router"
    if host.startswith("vllm"):
        return "vllm"
    if host == "infinity":
        return "infinity"
    if host == "embeddings":
        return "tei"
    if host == "ollama":
        return "ollama"
    if host == "llamacpp":
        return "llamacpp"
    if host == "stt":
        return "stt"
    # An IP, an FQDN or host.docker.internal: another stack (or a host-native
    # engine) — answered by that endpoint's own /capacity when it has one.
    return "remote"


def vllm_max_num_seqs(host: str) -> int | None:
    """The scheduler's ceiling for an instance. vLLM does not publish
    max_num_seqs in /metrics, so it comes from the same profile variable the
    instance was started with (compose passes it per instance)."""
    for suffix in ("_" + host.replace("-", "_").upper(), ""):
        raw = os.environ.get(f"CAPACITY_MAX_NUM_SEQS{suffix}")
        if raw and raw.strip().isdigit():
            return int(raw)
    return None


def router_instances(model: str) -> list[str]:
    """The vLLM roots the router sends *model* to (ROUTER_MODEL_n/HOST_n)."""
    hosts = []
    for i in (1, 2, 3):
        if os.environ.get(f"ROUTER_MODEL_{i}", "") == model and os.environ.get(f"ROUTER_HOST_{i}"):
            hosts.append("http://" + os.environ[f"ROUTER_HOST_{i}"])
    return hosts


# ---------------------------------------------------------------------------
# Per-engine readers. Each returns a dict of raw facts, or {"healthy": False}.
# ---------------------------------------------------------------------------

def read_vllm(root: str) -> dict:
    status, text = http_get(root + "/metrics")
    if status != 200:
        return {"healthy": False, "error": f"metrics HTTP {status or 'unreachable'}"}
    s = parse_prometheus(text)
    cache = labels_of(s, "vllm:cache_config_info")

    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    asleep = (first(s, "vllm:engine_sleep_state", sleep_state="awake") == 0.0)
    return {
        "healthy": not asleep,
        "error": "engine is asleep" if asleep else None,
        "running": total(s, "vllm:num_requests_running") or 0.0,
        "waiting": total(s, "vllm:num_requests_waiting") or 0.0,
        "kv_usage": total(s, "vllm:kv_cache_usage_perc") or 0.0,
        "kv_size_tokens": num(cache.get("kv_cache_size_tokens")),
        "kv_max_full_concurrency": num(cache.get("kv_cache_max_concurrency")),
        "max_num_seqs": vllm_max_num_seqs(host_of(root)),
        "counters": {
            "generation_tokens": total(s, "vllm:generation_tokens_total"),
            "prompt_tokens": total(s, "vllm:prompt_tokens_total"),
            "e2e_sum": total(s, "vllm:e2e_request_latency_seconds_sum"),
            "e2e_count": total(s, "vllm:e2e_request_latency_seconds_count"),
            "queue_sum": total(s, "vllm:request_queue_time_seconds_sum"),
            "queue_count": total(s, "vllm:request_queue_time_seconds_count"),
            "ttft_sum": total(s, "vllm:time_to_first_token_seconds_sum"),
            "ttft_count": total(s, "vllm:time_to_first_token_seconds_count"),
            "preemptions": total(s, "vllm:num_preemptions_total"),
        },
    }


def read_infinity(root: str, model_hint: str) -> dict:
    status, text = http_get(root + "/models")
    if status != 200:
        return {"healthy": False, "error": f"/models HTTP {status or 'unreachable'}"}
    try:
        models = json.loads(text).get("data", [])
    except ValueError:
        return {"healthy": False, "error": "unparseable /models"}
    hint = model_hint.rsplit("/", 1)[-1].lower()
    pick = next((m for m in models if hint and hint in str(m.get("id", "")).lower()), models[0] if models else None)
    if not pick:
        return {"healthy": False, "error": "no model loaded"}
    st = pick.get("stats") or {}
    return {
        "healthy": True,
        "model": pick.get("id"),
        "queue_fraction": float(st.get("queue_fraction") or 0.0),
        "queued": float(st.get("queue_absolute") or 0.0),
        "pending": float(st.get("results_pending") or 0.0),
        "batch_size": float(st.get("batch_size") or 0.0),
    }


def read_ollama(root: str) -> dict:
    status, text = http_get(root + "/api/ps")
    if status != 200:
        return {"healthy": False, "error": f"/api/ps HTTP {status or 'unreachable'}"}
    try:
        loaded = [m.get("name") for m in json.loads(text).get("models", [])]
    except ValueError:
        loaded = []
    return {"healthy": True, "loaded": loaded,
            "parallel": float(os.environ.get("OLLAMA_NUM_PARALLEL", "4") or 4)}


def read_llamacpp(root: str) -> dict:
    status, text = http_get(root + "/slots")
    if status != 200:
        # /slots is optional in llama-server; health alone still says up/down.
        h, _ = http_get(root + "/health")
        return {"healthy": h == 200, "error": None if h == 200 else f"/health HTTP {h or 'unreachable'}"}
    try:
        slots = json.loads(text)
    except ValueError:
        slots = []
    busy = sum(1 for sl in slots if sl.get("is_processing") or sl.get("state", 0) != 0)
    return {"healthy": True, "slots": float(len(slots)), "busy": float(busy)}


def read_health_only(root: str) -> dict:
    for path in ("/health", "/v1/models"):
        status, _ = http_get(root + path)
        if status == 200:
            return {"healthy": True}
    return {"healthy": False, "error": "health check failed"}


def read_remote(api_base: str, alias: str, key: str | None) -> dict:
    status, text = http_get(root_of(api_base) + "/capacity/" + alias, key=key)
    if status == 200:
        try:
            body = json.loads(text)
            return {"healthy": True, "remote": body.get("roles", {}).get(alias) or body}
        except ValueError:
            pass
    return {"healthy": None, "error": f"peer /capacity HTTP {status or 'unreachable'}"}


# ---------------------------------------------------------------------------
# Turning facts into advice
# ---------------------------------------------------------------------------

def state_for(load: float, waiting: float = 0.0) -> str:
    if waiting > 0 or load >= BUSY_BELOW:
        return "saturated"
    if load >= AVAILABLE_BELOW:
        return "busy"
    if load < 0.10:
        return "idle"
    return "available"


def recommend(state: str, free: float) -> int:
    """What ONE client should keep in flight. Busy halves the room so two
    clients reading the same number do not both take all of it."""
    if state in ("saturated", "down", "unknown") or free <= 0:
        return 0
    if state == "busy":
        return max(1, int(free // 2))
    return max(1, int(free))


def vllm_advice(f: dict, rates: dict, tokens: int | None) -> dict:
    cap = f.get("max_num_seqs")
    running, waiting, kv = f["running"], f["waiting"], f["kv_usage"]
    kv_size = f.get("kv_size_tokens")
    free_kv = max(0.0, (KV_HEADROOM_CEILING - kv)) * kv_size if kv_size else None

    slot_free = (cap - running - waiting) if cap else None
    slot_load = ((running + waiting) / cap) if cap else 0.0
    load = max(slot_load, kv)

    # A request of *tokens* needs that much KV; the free KV bounds how many
    # such requests can run at once, independent of the slot count.
    by_kv = (free_kv / tokens) if (free_kv is not None and tokens) else None
    candidates = [x for x in (slot_free, by_kv) if x is not None]
    free = max(0.0, min(candidates)) if candidates else max(0.0, (1 - load) * 8)

    state = state_for(load, waiting)
    out = {
        "in_flight": int(running),
        "waiting": int(waiting),
        "max_concurrency": cap,
        "kv_cache_usage": round(kv, 4),
        "kv_cache_tokens": int(kv_size) if kv_size else None,
        "free_kv_tokens": int(free_kv) if free_kv is not None else None,
        "max_full_context_concurrency": round(f["kv_max_full_concurrency"], 2) if f.get("kv_max_full_concurrency") else None,
        "free_slots": int(math.floor(free)),
        "load": round(load, 4),
        "state": state,
        "recommended_concurrency": recommend(state, math.floor(free)),
    }
    if state == "saturated":
        # A queued request waits roughly (queue depth / ceiling) x mean latency.
        lat = rates.get("mean_latency_s") or 10.0
        out["retry_after_s"] = round(max(1.0, lat * max(waiting, 1) / max(cap or 1, 1)), 1)
    return out


def infinity_advice(f: dict) -> dict:
    batch = f["batch_size"] or 32.0
    in_flight = f["queued"] + f["pending"]
    load = max(f["queue_fraction"], min(1.0, in_flight / (batch * 4)))
    # Infinity batches dynamically: up to a few batches in flight keep the GPU
    # fed without the queue growing.
    free = max(0.0, batch * 4 - in_flight)
    state = state_for(load)
    return {"in_flight": int(in_flight), "waiting": int(f["queued"]), "max_concurrency": int(batch * 4),
            "batch_size": int(batch), "free_slots": int(free), "load": round(load, 4), "state": state,
            "recommended_concurrency": recommend(state, free), "model": f.get("model")}


def ollama_advice(f: dict) -> dict:
    par = f["parallel"]
    # Ollama publishes no in-flight count, so this is the ceiling, not the room.
    return {"max_concurrency": int(par), "free_slots": None, "load": None, "state": "available",
            "recommended_concurrency": max(1, int(par // 2)), "loaded_models": f.get("loaded"),
            "note": "ollama does not expose in-flight requests; recommendation is half its parallel slots"}


def llamacpp_advice(f: dict) -> dict:
    if "slots" not in f:
        return {"state": "available", "recommended_concurrency": 1, "note": "/slots not enabled"}
    slots, busy = f["slots"], f["busy"]
    load = busy / slots if slots else 1.0
    state = state_for(load)
    free = slots - busy
    return {"in_flight": int(busy), "max_concurrency": int(slots), "free_slots": int(free), "load": round(load, 4),
            "state": state, "recommended_concurrency": recommend(state, free)}


# ---------------------------------------------------------------------------
# The poller: one snapshot per POLL_SECONDS, rates over RATE_WINDOW_SECONDS
# ---------------------------------------------------------------------------

class Poller:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.history: dict[str, list[tuple[float, dict]]] = {}
        self.facts: dict[str, dict] = {}
        self.gpus: list[dict] = []
        self.updated: float | None = None

    def roles(self) -> list[dict]:
        out = []
        for alias, alias_env, prefix in ROLES:
            alias = alias or os.environ.get(alias_env or "", "")
            if not alias.startswith("gpu/"):
                continue
            base = os.environ.get(f"{prefix}_API_BASE", "")
            if not base:
                continue
            model = os.environ.get(f"{prefix}_MODEL", "")
            key = os.environ.get(f"{prefix}_API_KEY") or None
            out.append({"alias": alias, "api_base": base, "model": model.split("/", 1)[-1] if "/" in model else model,
                        "key": None if key in (None, "", "EMPTY") else key, "kind": backend_kind(base)})
        return out

    def read_engine(self, role: dict) -> dict:
        kind, base = role["kind"], role["api_base"]
        if kind == "vllm":
            return read_vllm(root_of(base))
        if kind == "vllm-router":
            roots = router_instances(role["model"]) or [root_of(base)]
            parts = [read_vllm(r) for r in roots]
            ok = [p for p in parts if p.get("healthy")]
            if not ok:
                return parts[0]
            # The router spreads one model over its instances: sum their room.
            merged = dict(ok[0])
            for p in ok[1:]:
                for k in ("running", "waiting"):
                    merged[k] += p[k]
                merged["kv_usage"] = max(merged["kv_usage"], p["kv_usage"])
                if merged.get("max_num_seqs") and p.get("max_num_seqs"):
                    merged["max_num_seqs"] += p["max_num_seqs"]
                if merged.get("kv_size_tokens") and p.get("kv_size_tokens"):
                    merged["kv_size_tokens"] += p["kv_size_tokens"]
            return merged
        if kind == "infinity":
            return read_infinity(root_of(base), role["alias"])
        if kind == "ollama":
            return read_ollama(root_of(base))
        if kind == "llamacpp":
            return read_llamacpp(root_of(base))
        if kind == "remote":
            return read_remote(base, role["alias"], role["key"])
        return read_health_only(root_of(base))

    def poll_once(self) -> None:
        now = time.time()
        facts: dict[str, dict] = {}
        # One read per distinct engine: three chat roles on one vLLM cost one scrape.
        cache: dict[tuple, dict] = {}
        for role in self.roles():
            ck = (role["kind"], root_of(role["api_base"]), role["alias"] if role["kind"] in ("infinity", "remote") else "")
            if ck not in cache:
                cache[ck] = self.read_engine(role)
            facts[role["alias"]] = {"role": role, "facts": cache[ck]}
        gpus = read_gpus()
        with self.lock:
            self.facts = facts
            self.gpus = gpus
            self.updated = now
            for alias, entry in facts.items():
                counters = entry["facts"].get("counters")
                if counters:
                    hist = self.history.setdefault(alias, [])
                    hist.append((now, counters))
                    while hist and now - hist[0][0] > RATE_WINDOW_SECONDS:
                        hist.pop(0)

    def rates(self, alias: str) -> dict:
        hist = self.history.get(alias) or []
        if len(hist) < 2:
            return {}
        (t0, a), (t1, b) = hist[0], hist[-1]
        dt = t1 - t0
        if dt <= 0:
            return {}

        def delta(k):
            if a.get(k) is None or b.get(k) is None:
                return None
            d = b[k] - a[k]
            return d if d >= 0 else None  # a counter reset (engine restart)

        def mean(sum_k, count_k):
            s, c = delta(sum_k), delta(count_k)
            return round(s / c, 3) if s is not None and c else None

        gen, prompt, done = delta("generation_tokens"), delta("prompt_tokens"), delta("e2e_count")
        return {
            "window_s": round(dt, 1),
            "generation_tokens_per_s": round(gen / dt, 1) if gen is not None else None,
            "prompt_tokens_per_s": round(prompt / dt, 1) if prompt is not None else None,
            "requests_per_s": round(done / dt, 3) if done is not None else None,
            "mean_latency_s": mean("e2e_sum", "e2e_count"),
            "mean_queue_s": mean("queue_sum", "queue_count"),
            "mean_ttft_s": mean("ttft_sum", "ttft_count"),
            "preemptions": delta("preemptions"),
        }

    def report(self, tokens: int | None = None, only: str | None = None) -> dict:
        with self.lock:
            facts, gpus, updated = dict(self.facts), list(self.gpus), self.updated
        roles = {}
        for alias, entry in facts.items():
            if only and alias != only:
                continue
            role, f = entry["role"], entry["facts"]
            rates = self.rates(alias)
            base = {"backend": role["kind"], "model": role["model"] or f.get("model"), "healthy": f.get("healthy")}
            if f.get("healthy") is False:
                body = {"state": "down", "recommended_concurrency": 0, "error": f.get("error")}
            elif role["kind"] in ("vllm", "vllm-router"):
                body = vllm_advice(f, rates, tokens)
            elif role["kind"] == "infinity":
                body = infinity_advice(f)
            elif role["kind"] == "ollama":
                body = ollama_advice(f)
            elif role["kind"] == "llamacpp":
                body = llamacpp_advice(f)
            elif role["kind"] == "remote":
                body = f.get("remote") or {"state": "unknown", "recommended_concurrency": None, "error": f.get("error")}
                base["via"] = root_of(role["api_base"])
            else:
                body = {"state": "available" if f.get("healthy") else "unknown", "recommended_concurrency": None,
                        "note": "this engine publishes no load metrics; health only"}
            if rates:
                body["rates"] = rates
            roles[alias] = {**base, **body}
        return {
            "host": os.environ.get("CAPACITY_HOST_LABEL") or os.uname().nodename,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(updated)) if updated else None,
            "poll_seconds": POLL_SECONDS,
            "sized_for_tokens": tokens,
            "gpus": gpus,
            "roles": roles,
        }

    def run(self) -> None:
        while True:
            try:
                self.poll_once()
            except Exception as exc:  # a poll must never kill the service
                print(f"capacity: poll failed: {exc}", file=sys.stderr, flush=True)
            time.sleep(POLL_SECONDS)


def read_gpus() -> list[dict]:
    status, text = http_get(DCGM_URL)
    if status != 200:
        return []
    s = parse_prometheus(text)
    gpus: dict[str, dict] = {}
    for name, labels, v in s:
        key = labels.get("gpu")
        if key is None:
            continue
        g = gpus.setdefault(key, {"index": int(key) if key.isdigit() else key, "name": labels.get("modelName")})
        if name == "DCGM_FI_DEV_GPU_UTIL":
            g["utilization"] = round(v / 100, 3)
        elif name == "DCGM_FI_DEV_FB_USED":
            g["memory_used_mib"] = int(v)
        elif name == "DCGM_FI_DEV_FB_FREE":
            g["memory_free_mib"] = int(v)
        elif name == "DCGM_FI_DEV_GPU_TEMP":
            g["temperature_c"] = int(v)
        elif name == "DCGM_FI_DEV_POWER_USAGE":
            g["power_w"] = round(v, 1)
    return sorted(gpus.values(), key=lambda g: str(g["index"]))


# ---------------------------------------------------------------------------
# Prometheus exposition of the same report
# ---------------------------------------------------------------------------

STATE_CODE = {"idle": 0, "available": 1, "busy": 2, "saturated": 3, "down": 4, "unknown": 5}


def to_prometheus(report: dict) -> str:
    lines = [
        "# HELP gis_capacity_recommended_concurrency Requests one client should keep in flight for this role now.",
        "# TYPE gis_capacity_recommended_concurrency gauge",
        "# HELP gis_capacity_free_slots Requests the serving engine can start now.",
        "# TYPE gis_capacity_free_slots gauge",
        "# HELP gis_capacity_load Larger of slot use and KV-cache use, 0..1.",
        "# TYPE gis_capacity_load gauge",
        "# HELP gis_capacity_state 0 idle, 1 available, 2 busy, 3 saturated, 4 down, 5 unknown.",
        "# TYPE gis_capacity_state gauge",
    ]
    for alias, r in report["roles"].items():
        lbl = f'role="{alias}",backend="{r.get("backend")}"'
        for metric, key in (("recommended_concurrency", "recommended_concurrency"), ("free_slots", "free_slots"),
                            ("load", "load")):
            if isinstance(r.get(key), (int, float)):
                lines.append(f"gis_capacity_{metric}{{{lbl}}} {r[key]}")
        lines.append(f"gis_capacity_state{{{lbl}}} {STATE_CODE.get(r.get('state'), 5)}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

POLLER = Poller()


class Handler(BaseHTTPRequestHandler):
    server_version = "gis-capacity/1"

    def log_message(self, fmt, *args):  # quiet: LiteLLM already logs the request
        pass

    def _send(self, status: int, body: str, ctype: str = "application/json") -> None:
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        url = urllib.parse.urlsplit(self.path)
        qs = urllib.parse.parse_qs(url.query)
        path = url.path.rstrip("/") or "/"
        if path == "/health":
            return self._send(200, json.dumps({"ok": POLLER.updated is not None}))
        tokens = None
        if qs.get("tokens"):
            try:
                tokens = max(1, int(qs["tokens"][0]))
            except ValueError:
                return self._send(400, json.dumps({"error": "tokens must be an integer"}))
        if path == "/metrics":
            return self._send(200, to_prometheus(POLLER.report(tokens)), "text/plain; version=0.0.4")
        if path == "/capacity":
            return self._send(200, json.dumps(POLLER.report(tokens), indent=2))
        if path.startswith("/capacity/"):
            alias = path[len("/capacity/"):]
            report = POLLER.report(tokens, only=alias)
            if alias not in report["roles"]:
                known = sorted(POLLER.report()["roles"])
                return self._send(404, json.dumps({"error": f"no such role on this box: {alias}", "roles": known}))
            return self._send(200, json.dumps(report, indent=2))
        return self._send(404, json.dumps({"error": "see /capacity"}))


def main() -> None:
    POLLER.poll_once()
    threading.Thread(target=POLLER.run, daemon=True).start()
    print(f"capacity: serving on :{PORT}, polling every {POLL_SECONDS:g}s", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
