#!/usr/bin/env python3
"""Let this stack's virtual keys read GET /capacity.

WHY. /capacity is an authenticated LiteLLM pass-through (config/litellm/
config.yaml), and LiteLLM 1.102 does not open an auth=true pass-through to a
key just because the key is valid: the key's (or its team's) metadata must
list the route in `allowed_passthrough_routes`, or the call is a 403 —
"Key/team not allowed to access passthrough route /capacity". Keys minted
before the route existed have no such entry, so every existing consumer would
see the endpoint as forbidden and fall back to sizing blind.

This adds "/capacity" to each key's metadata, keeping every other metadata
field and every other allowed route. `make start` and deploy.sh run it after
every start (--wait --quiet), so a key minted by hand is granted on the next
start; keys minted with the .env.example recipe already carry it. Idempotent.

Usage:  python3 scripts/grant-capacity-access.py [--dry-run] [--alias NAME ...]
        Reads LITELLM_MASTER_KEY and LITELLM_PORT the way deploy.sh does:
        the environment, then the active profile's env files and .env.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

ROUTE = "/capacity"
REPO = Path(__file__).resolve().parents[1]


def env_files() -> list[Path]:
    """The env files deploy.sh layers, in order (lib-profile.sh), else just .env."""
    import shlex
    import subprocess

    try:
        out = subprocess.run(["bash", "-c", ". scripts/lib-profile.sh && profile_env_file_args"],
                             cwd=REPO, capture_output=True, text=True, timeout=10).stdout
        args = shlex.split(out)
        files = [Path(args[i + 1]) for i, a in enumerate(args[:-1]) if a == "--env-file"]
    except (OSError, subprocess.SubprocessError):
        files = []
    return files or [REPO / ".env"]


def dotenv(name: str) -> str | None:
    """*name* as deploy.sh would see it: the environment, else the last env file setting it."""
    if os.environ.get(name):
        return os.environ[name]
    value = None
    for path in env_files():
        if path.exists():
            for line in path.read_text().splitlines():
                if line.startswith(f"{name}="):
                    value = line.split("=", 1)[1].strip().strip('"')
    return value


def call(base: str, master: str, method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        base + path, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {master}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode() or "{}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--alias", action="append", help="only keys with this key_alias (repeatable)")
    ap.add_argument("--base", default=None, help="gateway root (default http://localhost:$LITELLM_PORT)")
    ap.add_argument("--wait", type=int, default=0, metavar="S",
                    help="wait up to S seconds for the gateway to answer (right after a start)")
    ap.add_argument("--quiet", action="store_true", help="print only what changed")
    args = ap.parse_args()

    master = dotenv("LITELLM_MASTER_KEY")
    if not master:
        print("LITELLM_MASTER_KEY not set (env or .env)", file=sys.stderr)
        return 2
    base = (args.base or f"http://localhost:{dotenv('LITELLM_PORT') or 8080}").rstrip("/")

    deadline = time.monotonic() + args.wait
    while True:
        try:
            urllib.request.urlopen(base + "/health/liveliness", timeout=5).read()
            break
        except OSError:
            if time.monotonic() >= deadline:
                print(f"gateway at {base} is not answering", file=sys.stderr)
                return 1
            time.sleep(3)

    keys, page = [], 1
    while True:
        got = call(base, master, "GET", f"/key/list?return_full_object=true&size=100&page={page}")
        keys += got.get("keys") or []
        if page >= int(got.get("total_pages") or 1):
            break
        page += 1

    changed = 0
    for k in keys:
        alias = k.get("key_alias") or "(no alias)"
        if args.alias and alias not in args.alias:
            continue
        meta = dict(k.get("metadata") or {})
        routes = list(meta.get("allowed_passthrough_routes") or [])
        if ROUTE in routes:
            if not args.quiet:
                print(f"  = {alias}: already allowed")
            continue
        meta["allowed_passthrough_routes"] = routes + [ROUTE]
        print(f"  + {alias}: allow {ROUTE}" + (" (dry run)" if args.dry_run else ""))
        if not args.dry_run:
            call(base, master, "POST", "/key/update", {"key": k["token"], "metadata": meta})
        changed += 1
    if changed or not args.quiet:
        print(f"{changed} key(s) {'would be ' if args.dry_run else ''}updated, {len(keys)} on {base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
