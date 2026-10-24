#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo -e "${GREEN}GPU Inference Stack - Deployment Script${NC}"
echo "========================================"
echo ""

# Check if .env exists
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo -e "${YELLOW}Warning: .env file not found!${NC}"
    echo "Creating .env from .env.example..."
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "${YELLOW}Please edit .env with your configuration and run this script again.${NC}"
    exit 1
fi

# Load the active server profile, then .env on top.
#
# Order matters and mirrors what compose is given below: the committed profile
# supplies this box's hardware, models and role wiring; .env overrides with
# secrets and any local one-off. Sourcing .env LAST is what makes it win.
#
# shellcheck source=lib-profile.sh
. "$SCRIPT_DIR/lib-profile.sh"

# The WHOLE chain, base first, then .env — not just the selected profile.
# A profile that inherits holds only EXTENDS and SERVER_NAME, so sourcing it
# alone would leave every ENABLE_* unset and deploy a box with no services.
while IFS= read -r _f; do
    # shellcheck disable=SC1090
    source "$_f"
done < <("$SCRIPT_DIR/profile-files.sh")

# A named-but-missing profile must stop the deploy: silently falling through to
# compose defaults written for a different class of card is how a box ends up
# serving a model it cannot hold.
if ! profile_assert_resolvable >/dev/null 2>&1; then
    profile_assert_resolvable
    exit 1
fi

# Every compose invocation below gets the same layering. Unquoted on purpose —
# profile_env_file_args emits separate --env-file words.
# shellcheck disable=SC2046
DC=(docker compose $(profile_env_file_args) -f "$PROJECT_ROOT/docker-compose.yml")

# ---------------------------------------------------------------------------
# ENGINE EXCLUSIVITY  —  vLLM and llama.cpp cannot share a GPU here.
#
# This box's llama.cpp weights are 33.19 GiB of 48 GB; the Blackwell box's
# Flash-Next is 76.3 GiB of 97 GB. vLLM wants ~31 GB on top of either, so
# neither fits. And two engines contending for one card does not fail
# cleanly — it OOMs mid-request or thrashes, which reaches a consumer as
# intermittent 5xx and timeouts rather than as a configuration error.
# So refuse here, loudly, at deploy time.
#
# This runs BEFORE the Docker prerequisite check on purpose: a config that
# can never work should be rejected without touching the daemon.
#
# A genuinely multi-GPU box that has pinned the two engines to different
# devices (GPU_DEVICES vs LLAMACPP_GPU_DEVICES) can override.
# ---------------------------------------------------------------------------
if [ "${ENABLE_VLLM}" = "true" ] && [ "${ENABLE_LLAMACPP}" = "true" ]; then
    if [ "${ALLOW_VLLM_LLAMACPP_COTENANCY:-0}" != "1" ]; then
        echo -e "${RED}Error: ENABLE_VLLM and ENABLE_LLAMACPP are both true.${NC}"
        echo ""
        echo "  These engines are mutually exclusive on a single GPU. Enable the"
        echo "  one this box is meant to serve and disable the other:"
        echo ""
        echo "    vLLM       ->  ENABLE_VLLM=true   ENABLE_LLAMACPP=false"
        echo "    llama.cpp  ->  ENABLE_VLLM=false  ENABLE_LLAMACPP=true"
        echo ""
        echo "  If this box has more than one GPU and you have pinned them to"
        echo "  different devices (GPU_DEVICES vs LLAMACPP_GPU_DEVICES), set"
        echo "  ALLOW_VLLM_LLAMACPP_COTENANCY=1 to proceed."
        exit 1
    fi
    echo -e "${YELLOW}Warning: running vLLM and llama.cpp together (cotenancy override set).${NC}"
    echo "  GPU_DEVICES=${GPU_DEVICES:-0}  LLAMACPP_GPU_DEVICES=${LLAMACPP_GPU_DEVICES:-${GPU_DEVICES:-0}}"
    echo "  Both engines will attempt to reserve VRAM. Verify with nvidia-smi."
fi

# A box with no chat engine cannot serve gpu/chat/interactive, /bulk or /fast —
# all three of which are REQUIRED contract roles. Warn rather than fail: an
# embed/rerank-only box is a legitimate deployment, and so is a box being
# brought up in stages.
if [ "${ENABLE_VLLM}" != "true" ] && [ "${ENABLE_LLAMACPP}" != "true" ]; then
    echo -e "${YELLOW}Warning: neither vLLM nor llama.cpp is enabled.${NC}"
    echo "  The required gpu/chat/* contract roles will be UNSERVED, and"
    echo "  scripts/health-check.sh will report contract failures. A consumer"
    echo "  pointed at this box will refuse to start."
    echo ""
fi

echo "Configuration:"
echo "  Server Name: ${SERVER_NAME:-gpu-server-1}"
profile_assert_resolvable
echo "  GPU Devices: ${GPU_DEVICES:-0}"
echo ""

# Check Docker and NVIDIA runtime
echo "Checking prerequisites..."
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

if ! docker info | grep -q "Runtimes.*nvidia"; then
    echo -e "${YELLOW}Warning: NVIDIA Docker runtime not detected${NC}"
    echo "Make sure nvidia-docker2 is installed for GPU support"
fi

echo -e "${GREEN}✓ Docker is available${NC}"
echo ""

# Refuse to deploy a stack whose config reads variables the container is never
# given. The role guard further down checks the CONTRACT_* variables are SET;
# this checks they are FORWARDED, which is a different failure and the one that
# shipped broken on 2026-09-10 — twelve variables read by config.yaml, none
# passed by docker-compose.yml, all six aliases published and every request to
# them failing. See docs/superpowers/specs/2026-09-10-portable-across-servers-and-models.md
if [ -x "$SCRIPT_DIR/check-contract-wiring.sh" ]; then
    if ! "$SCRIPT_DIR/check-contract-wiring.sh"; then
        echo -e "${RED}Refusing to deploy: the contract would be published but unwired.${NC}"
        exit 1
    fi
    echo ""
fi

# Create data directories
echo "Creating data directories..."
mkdir -p "$PROJECT_ROOT/data"/{ollama/models,vllm/cache,llamacpp/models,huggingface,prometheus,grafana,postgres}
# Try to set permissions, ignore errors for directories owned by Docker
chmod -R 755 "$PROJECT_ROOT/data" 2>/dev/null || true
echo -e "${GREEN}✓ Data directories created${NC}"
echo ""

# Determine which profiles to enable
# Note: redis and postgres always run (required by LiteLLM)
PROFILES="litellm,prometheus,grafana,node-exporter,dcgm-exporter"

if [ "${ENABLE_OLLAMA}" = "true" ]; then
    PROFILES="$PROFILES,ollama"
    echo "Enabling Ollama..."
fi

if [ "${ENABLE_VLLM}" = "true" ]; then
    PROFILES="$PROFILES,vllm"
    echo "Enabling vLLM..."
fi

# Additional chat instances. Only the 97 GB box has room for more than one;
# a profile that enables these on a smaller card will simply fail to start the
# second container, because vLLM preallocates its share of the WHOLE GPU.
for _n in 2 3; do
    eval "_on=\${ENABLE_VLLM${_n}:-false}"
    if [ "$_on" = "true" ]; then
        PROFILES="$PROFILES,vllm${_n}"
        eval "_m=\${VLLM${_n}_MODEL_NAME:-<inherits instance 1>}"
        echo "Enabling vLLM instance ${_n} ($_m)..."
    fi
done

# vllm-router. Default ON, so every box that had it keeps it. Off is for a box
# with ONE instance and no consumer addressing the engine through the router:
# there it is an extra hop and a container for nothing. Multi-instance forces it
# back on regardless of the flag — with two models behind one port, the router
# IS the thing that picks between them, and running without it would route every
# request to instance 1.
if [ "${ENABLE_VLLM}" = "true" ]; then
    _router="${ENABLE_VLLM_ROUTER:-true}"
    if [ "${ENABLE_VLLM2:-false}" = "true" ] || [ "${ENABLE_VLLM3:-false}" = "true" ]; then
        if [ "$_router" != "true" ]; then
            echo "Enabling vLLM router (forced: more than one vLLM instance)..."
        fi
        _router=true
    fi
    if [ "$_router" = "true" ]; then
        PROFILES="$PROFILES,vllm-router"
    else
        echo "vLLM router disabled (single instance, ENABLE_VLLM_ROUTER=false)."
    fi
fi

# llama.cpp — the alternative chat engine. Exclusivity with vLLM was already
# enforced above, so at most one of these two branches can be taken.
if [ "${ENABLE_LLAMACPP}" = "true" ]; then
    PROFILES="$PROFILES,llamacpp"
    echo "Enabling llama.cpp..."
fi

# Infinity serves the contract's embed + rerank roles. Defaults ON: a stack
# with no embedder cannot serve a consumer's retrieval plane at all.
if [ "${ENABLE_INFINITY:-true}" = "true" ]; then
    PROFILES="$PROFILES,infinity"
    echo "Enabling Infinity (embeddings + reranking)..."
fi

# >>> stt role (scripts/tests/test_stt_role.sh runs this block on its own)
# Speech-to-text. OFF by default, and the switch publishes the alias too: the
# compose default is unserved/stt, so a box without the backend never lists a
# dead gpu/stt/whisper. An explicit CONTRACT_STT_ALIAS still wins.
if [ "${ENABLE_STT:-false}" = "true" ]; then
    PROFILES="$PROFILES,stt"
    export CONTRACT_STT_ALIAS="${CONTRACT_STT_ALIAS:-gpu/stt/whisper}"
    echo "Enabling speech-to-text (${STT_DEVICE:-cpu})..."
fi
# <<< stt role

if [ "${ENABLE_EMBEDDINGS}" = "true" ]; then
    PROFILES="$PROFILES,embeddings"
    echo "Enabling Text Embeddings (TEI)..."
fi

echo ""
echo "Active profiles: $PROFILES"
echo ""

# ---------------------------------------------------------------------------
# CONTRACT / BACKEND CONSISTENCY
#
# A contract alias whose backend is not running is WORSE than an absent one.
# LiteLLM publishes every alias in config.yaml regardless of whether its
# api_base answers, so:
#   - /v1/models lists the role
#   - a consumer's boot check sees it and assumes the role is available
#   - every real call then 500s ("Cannot connect to host ollama:11434")
#
# "Unserved" and "published but broken" are opposite states that look
# identical from outside, which is the same trap as the Pillow and no-curl
# bugs this repo has already fixed. Catch it here instead.
#
# Truly unserving an OPTIONAL role needs the alias commented out of
# config/litellm/config.yaml as well — .env alone cannot remove it.
_contract_warn=0
_check_backend() {
    # $1 = role label, $2 = that role's api_base, $3 = host substring,
    # $4 = whether its service is enabled
    case "$2" in
        *"$3"*)
            if [ "$4" != "true" ]; then
                [ "$_contract_warn" = "0" ] && echo -e "${YELLOW}Warning: contract roles point at disabled backends.${NC}"
                _contract_warn=1
                echo "  $1 -> $3, but that service is not enabled."
            fi
            ;;
    esac
}
_check_backend "gpu/chat/vision"  "${CONTRACT_VISION_API_BASE:-http://ollama:11434}"  "ollama"   "${ENABLE_OLLAMA}"
_check_backend "gpu/embed/bge-m3" "${CONTRACT_EMBED_API_BASE:-http://infinity:7997}"  "infinity" "${ENABLE_INFINITY:-true}"
_check_backend "gpu/rerank/*"     "${CONTRACT_RERANK_API_BASE:-http://infinity:7997}" "infinity" "${ENABLE_INFINITY:-true}"
for _role in INTERACTIVE BULK FAST; do
    eval "_base=\${CONTRACT_${_role}_API_BASE:-http://vllm:8000/v1}"
    _check_backend "gpu/chat/$(echo "$_role" | tr 'A-Z' 'a-z')" "$_base" "vllm"     "${ENABLE_VLLM}"
    _check_backend "gpu/chat/$(echo "$_role" | tr 'A-Z' 'a-z')" "$_base" "llamacpp" "${ENABLE_LLAMACPP}"
done
if [ "$_contract_warn" = "1" ]; then
    echo ""
    echo "  For an OPTIONAL role (vision, ocr) also comment out its block in"
    echo "  config/litellm/config.yaml — otherwise the alias stays published in"
    echo "  /v1/models and consumers will route to it and get 500s."
    echo "  For a REQUIRED role, enable the backend instead."
    echo ""
fi

# Same "published but broken" trap, one axis over: the api_base vars above all
# have a :- fallback, but CONTRACT_<ROLE>_MODEL has NONE — config/litellm reads
# `model: os.environ/CONTRACT_<ROLE>_MODEL` bare for the chat roles. Unset,
# LiteLLM still publishes the alias and every request to it 500s, which from
# outside is indistinguishable from a role this box does not serve.
#
# Not hypothetical, and not always a mistake: server-blackwell-97gb.env
# deliberately serves neither bulk nor fast (Flash-Next is effectively
# single-slot at 97 GB, and `fast` carries a 60s timeout), while
# server-default.env / -high-vram.env / -multi-gpu.env bind no chat role at
# all. The first is a design decision and the last three are unfinished
# profiles, and an unset variable cannot tell them apart.
#
# So say which: list intentionally-unserved roles in CONTRACT_UNSERVED_ROLES.
# A role that is neither bound nor declared unserved stops the deploy.
#
#   CONTRACT_UNSERVED_ROLES="bulk fast"
#
# Declaring a role unserved does NOT unpublish its alias — config/litellm is
# shared by every profile, so /v1/models still lists it. That is the consumer's
# cue to address the role on a box that serves it (gpu.<server>/chat/bulk),
# which is what the contract's server-addressed indirection is for.
_unserved=" $(echo "${CONTRACT_UNSERVED_ROLES:-}" | tr 'A-Z' 'a-z') "
_unbound=""
for _role in INTERACTIVE BULK FAST; do
    _lc="$(echo "$_role" | tr 'A-Z' 'a-z')"
    eval "_model=\${CONTRACT_${_role}_MODEL:-}"
    eval "_alias=\${CONTRACT_${_role}_ALIAS:-}"
    case "$_unserved" in *" $_lc "*) continue ;; esac
    if [ -z "$_model" ] && [ -z "$_alias" ]; then
        _unbound="$_unbound gpu/chat/$_lc"
    fi
done
if [ -n "$_unbound" ]; then
    echo -e "${RED}Contract roles are PUBLISHED but UNBOUND:${NC}"
    for _r in $_unbound; do echo "  $_r — no CONTRACT_*_MODEL set"; done
    echo ""
    echo "  LiteLLM publishes these in /v1/models and every request to them"
    echo "  returns 500, so a consumer cannot tell them from a working role."
    echo ""
    echo "  Either bind them in your servers/*.env — one model may serve"
    echo "  several roles, as server-a6000-48gb.env points all three chat"
    echo "  roles at the same weights — or declare the omission:"
    echo ""
    echo "      CONTRACT_UNSERVED_ROLES=\"bulk fast\""
    echo ""
    echo "  Refusing to deploy a stack that lies about what it serves."
    echo "  ALLOW_UNBOUND_CONTRACT_ROLES=1 overrides, for a live migration."
    if [ "${ALLOW_UNBOUND_CONTRACT_ROLES:-0}" != "1" ]; then
        exit 1
    fi
fi
if [ -n "${CONTRACT_UNSERVED_ROLES:-}" ]; then
    echo -e "${YELLOW}Roles declared UNSERVED on this box:${NC} ${CONTRACT_UNSERVED_ROLES}"
    echo "  Their aliases stay in /v1/models (config/litellm is shared)."
    echo "  Consumers must reach those roles on a box that serves them."
    echo ""
fi

# Pull images.
# --ignore-buildable: litellm is built from config/litellm/Dockerfile (it needs
# Pillow for the Ollama vision path), so it has no upstream tag to pull. Under
# `set -e` a pull that trips over a locally-built image aborts the whole deploy.
echo "Pulling Docker images..."
COMPOSE_PROFILES="$PROFILES" "${DC[@]}" pull --ignore-buildable

echo ""
echo "Building local images..."
COMPOSE_PROFILES="$PROFILES" "${DC[@]}" build

echo ""
echo -e "${GREEN}Starting services...${NC}"
COMPOSE_PROFILES="$PROFILES" "${DC[@]}" up -d

echo ""
echo "Waiting for services to initialize (this may take 2-5 minutes for vLLM)..."
sleep 30

# ---------------------------------------------------------------------------
# Pull the Ollama models this box is configured to serve.
#
# Nothing else does this. OLLAMA_PRELOAD_MODELS and OLLAMA_VISION_MODEL were
# documented as configuration but never acted on, so a fresh deploy published
# the gpu/chat/vision alias in front of a model Ollama did not have — LiteLLM
# resolves the alias, Ollama 404s on the pull-less model name, and the
# consumer sees a vision failure that looks like a routing bug.
# ---------------------------------------------------------------------------
if [ "${ENABLE_OLLAMA}" = "true" ]; then
    OLLAMA_MODELS_TO_PULL="${OLLAMA_PRELOAD_MODELS:-} ${OLLAMA_VISION_MODEL:-}"
    if [ -n "${OLLAMA_MODELS_TO_PULL// /}" ]; then
        echo ""
        echo "Pulling Ollama models..."
        # Wait for the API before pulling; a cold container is not up at +30s.
        for _ in $(seq 1 30); do
            docker exec ollama ollama list >/dev/null 2>&1 && break
            sleep 5
        done
        for model in $(echo "$OLLAMA_MODELS_TO_PULL" | tr -d '"' | tr ' ' '\n' | sort -u); do
            [ -z "$model" ] && continue
            if docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$model"; then
                echo -e "  ${GREEN}✓${NC} $model (already present)"
                continue
            fi
            echo "  pulling $model ..."
            if docker exec ollama ollama pull "$model"; then
                echo -e "  ${GREEN}✓${NC} $model"
            else
                echo -e "  ${RED}✗ $model failed to pull${NC} — gpu/chat/vision will not serve"
            fi
        done
    fi
fi

# Consumer keys need /capacity in their metadata or LiteLLM answers 403 and
# every consumer sizes blind (README "Load"). Idempotent; never fails a deploy.
python3 "$SCRIPT_DIR/grant-capacity-access.py" --wait 180 --quiet \
    || echo -e "${YELLOW}! could not grant /capacity to consumer keys — run: python3 scripts/grant-capacity-access.py${NC}"

# Check service health
echo ""
echo "Service Status:"
"${DC[@]}" ps

echo ""
echo -e "${GREEN}Deployment complete!${NC}"
echo ""
# Print the address LiteLLM is ACTUALLY on. `localhost` is wrong wherever
# LITELLM_BIND_ADDR is pinned — and on a box where something else holds :8080
# (which is why it gets pinned) the printed URL points at that other service.
# Handing someone a URL that resolves to a different app is worse than
# printing nothing. 0.0.0.0 and [::] do include loopback, so those stay.
_addr="${LITELLM_BIND_ADDR:-localhost}"
case "$_addr" in ""|0.0.0.0|"[::]"|"::") _addr="localhost" ;; esac

echo "Access points:"
echo "  LiteLLM API: http://${_addr}:${LITELLM_PORT:-8080}/v1"
echo "  LiteLLM UI:  http://${_addr}:${LITELLM_PORT:-8080}/ui"
echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000} (admin/***)"
echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT:-9090}"

if [ "${ENABLE_OLLAMA}" = "true" ]; then
    echo "  Ollama:      http://localhost:${OLLAMA_PORT:-11434}"
fi

if [ "${ENABLE_VLLM}" = "true" ]; then
    echo "  vLLM:        http://localhost:${VLLM_PORT:-8100}"
fi

if [ "${ENABLE_LLAMACPP}" = "true" ]; then
    # Loopback by default and deliberately — llama-server has no auth. This is
    # for local debugging and scripts/benchmark.sh --direct, not for consumers.
    echo "  llama.cpp:   http://${LLAMACPP_BIND_ADDR:-127.0.0.1}:${LLAMACPP_PORT:-8083}  (no auth — local only)"
fi

echo ""
echo "To view logs: docker compose logs -f [service-name]"
echo "To stop: docker compose down"
echo ""
