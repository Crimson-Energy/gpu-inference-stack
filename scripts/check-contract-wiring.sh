#!/usr/bin/env bash
# Assert that every variable config/litellm/config.yaml reads is actually
# passed to the litellm container.
#
# WHY THIS EXISTS. On 2026-09-10 config.yaml read twelve `os.environ/CONTRACT_*`
# variables and docker-compose.yml passed none of them. LiteLLM published all
# six contract aliases in /v1/models anyway, and every request to them failed —
# which from a consumer's side is indistinguishable from a healthy stack with a
# broken model.
#
# Nothing else catches this. deploy.sh's role guard checks the variables are set
# in the *shell*; it cannot know the container never received them.
# health-check.sh probes /v1/models, which lists the aliases whether or not they
# resolve. The two files simply drifted apart, and only a check that reads both
# can see it.
#
# The check is deliberately generic — it does not know what CONTRACT_ means. It
# extracts `os.environ/NAME` from the config and compares against the names the
# rendered compose passes to litellm, so it covers any future variable too.
#
# Usage:  scripts/check-contract-wiring.sh [--quiet]
# Exit:   0 = every referenced variable is forwarded
#         1 = at least one is not (names printed)
#         2 = could not run the check (missing file, compose render failed)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_DIR/config/litellm/config.yaml"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'

if [ ! -f "$CONFIG" ]; then
    echo "${RED}✗ not found: $CONFIG${NC}" >&2
    exit 2
fi

# ── What the config asks for ────────────────────────────────────────────────
# `os.environ/NAME` is LiteLLM's own indirection syntax. Matches it wherever it
# appears — api_base, model, api_key, or a model_name (CONTRACT_VISION_ALIAS is
# read as the alias itself).
referenced="$(grep -oE 'os\.environ/[A-Za-z_][A-Za-z0-9_]*' "$CONFIG" \
              | sed 's|os\.environ/||' | sort -u)"

if [ -z "$referenced" ]; then
    [ "$QUIET" = 1 ] || echo "${DIM}no os.environ/ references in config.yaml — nothing to check${NC}"
    exit 0
fi

# ── What the container is given ─────────────────────────────────────────────
# Read the RENDERED config, not the raw YAML: that resolves ${VAR:-default}
# and any override file, which is what actually reaches the container. Every
# profile is enabled so litellm is always present in the render.
# Layer the active server profile in, exactly as deploy.sh does — otherwise
# this renders a box's config with someone else's defaults and its verdict
# would not describe the machine it is running on.
# shellcheck source=lib-profile.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-profile.sh"
# shellcheck disable=SC2046
rendered="$(cd "$REPO_DIR" && docker compose $(profile_env_file_args) \
    --profile vllm --profile vllm2 --profile vllm3 \
    --profile llamacpp --profile ollama \
    --profile embeddings --profile infinity --profile nginx \
    config 2>/dev/null)"
if [ -z "$rendered" ]; then
    echo "${RED}✗ could not render compose config${NC}" >&2
    echo "${DIM}  run: docker compose config${NC}" >&2
    exit 2
fi

# The litellm service's environment block, as `NAME: value` or `- NAME=value`.
# python3 rather than awk: the render is YAML and indentation-sensitive, and
# getting the service boundary wrong would silently pass everything.
provided="$(printf '%s' "$rendered" | python3 -c '
import sys, yaml
try:
    doc = yaml.safe_load(sys.stdin) or {}
except yaml.YAMLError:
    sys.exit(0)
env = ((doc.get("services") or {}).get("litellm") or {}).get("environment") or {}
if isinstance(env, dict):
    names = env.keys()
elif isinstance(env, list):
    names = [str(e).split("=", 1)[0] for e in env]
else:
    names = []
print("\n".join(sorted(set(names))))
' 2>/dev/null)"

# ── Compare ────────────────────────────────────────────────────────────────
missing=""
for name in $referenced; do
    if ! printf '%s\n' "$provided" | grep -qx -- "$name"; then
        missing="$missing $name"
    fi
done

n_ref="$(printf '%s\n' "$referenced" | grep -c . || true)"

# ── litellm ↔ capacity ─────────────────────────────────────────────────────
# The capacity service measures load on whatever engine each role points at,
# and learns that from its own copy of the CONTRACT_* block. A role re-pointed
# for litellm but not for capacity would report the OLD engine's load as the
# role's — consumers would size their concurrency against the wrong GPU. So
# every CONTRACT_* name capacity is given must reach litellm with the SAME
# rendered value. (litellm may carry names capacity does not measure, e.g.
# CONTRACT_OCR_API_BASE.)
drift="$(printf '%s' "$rendered" | python3 -c '
import sys, yaml
try:
    doc = yaml.safe_load(sys.stdin) or {}
except yaml.YAMLError:
    sys.exit(0)
def env(svc):
    e = ((doc.get("services") or {}).get(svc) or {}).get("environment") or {}
    if isinstance(e, list):
        e = dict((str(x).split("=", 1) + [""])[:2] for x in e)
    return {k: ("" if v is None else str(v)) for k, v in e.items() if k.startswith("CONTRACT_")}
cap, lite = env("capacity"), env("litellm")
for name in sorted(cap):
    if name not in lite:
        print(f"{name}: given to capacity, not to litellm")
    elif cap[name] != lite[name]:
        print(f"{name}: litellm and capacity render different values")

# litellm stamps a vLLM priority per role only when VLLM_SCHEDULING_POLICY is
# "priority", and vLLM rejects a non-zero priority unless IT runs that policy
# (config/litellm/role_priority.py). A mismatch fails every bulk request.
def raw_env(svc):
    e = ((doc.get("services") or {}).get(svc) or {}).get("environment") or {}
    if isinstance(e, list):
        e = dict((str(x).split("=", 1) + [""])[:2] for x in e)
    return {k: ("" if v is None else str(v)) for k, v in e.items()}
policy = raw_env("litellm").get("VLLM_SCHEDULING_POLICY", "")
for svc in ("vllm", "vllm2", "vllm3"):
    if svc in (doc.get("services") or {}):
        theirs = raw_env(svc).get("GIS_SCHEDULING_POLICY", "")
        if theirs != policy:
            print(f"VLLM_SCHEDULING_POLICY: litellm stamps for {policy!r}, {svc} runs {theirs!r}")
' 2>/dev/null)"

if [ -z "$missing" ] && [ -z "$drift" ]; then
    [ "$QUIET" = 1 ] || echo "${GREEN}✓${NC} contract wiring: all $n_ref variable(s) read by config.yaml are passed to litellm, and capacity sees the same roles"
    exit 0
fi

if [ -n "$drift" ]; then
    echo ""
    echo "${RED}✗ litellm disagrees with the capacity service or vLLM:${NC}"
    printf '%s\n' "$drift" | sed 's/^/    /'
    echo ""
    echo "  A CONTRACT_* drift makes /capacity report another engine's load for a"
    echo "  role: keep the capacity service's CONTRACT_* lines identical to"
    echo "  litellm's (values are not printed: some are keys). A scheduling-policy"
    echo "  drift makes vLLM reject every stamped request: litellm and every vLLM"
    echo "  instance must read the same VLLM_SCHEDULING_POLICY."
    [ -z "$missing" ] && exit 1
fi

echo ""
echo "${RED}✗ config/litellm/config.yaml reads variables the litellm container never receives:${NC}"
for name in $missing; do
    echo "    $name"
done
echo ""
echo "  LiteLLM will still publish the affected aliases in /v1/models, and every"
echo "  request to them will fail. A consumer cannot tell that apart from a"
echo "  healthy stack serving a broken model, so this is refused here instead."
echo ""
# One worked example, using the first missing name — not all of them
# concatenated, which is what a bare ${missing} would print.
first="${missing## }"; first="${first%% *}"
echo "${YELLOW}  Fix:${NC} add each name to the litellm service's ${DIM}environment:${NC} block in"
echo "       docker-compose.yml, with a default describing this box's topology, e.g."
echo ""
echo "${DIM}         - ${first}=\${${first}:-http://vllm:8000/v1}${NC}"
echo ""
exit 1
