# gpu-inference-stack
#
#   git pull && make setup && make start
#
# `setup` works out which box this is, confirms it with you, writes the choice
# into .env, checks the machine can actually run the profile, and pulls/builds
# everything. `start` runs it and tells you what is serving and where.
#
# Everything routes through scripts/dc.sh so the active server profile is
# layered under .env on every compose call. A bare `docker compose` reads .env
# alone and silently falls back to defaults written for a different card.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT := $(shell cd "$(dirname $(firstword $(MAKEFILE_LIST)))" && pwd)
DC   := ./scripts/dc.sh

BOLD := $(shell tput bold 2>/dev/null)
DIM  := $(shell tput dim 2>/dev/null)
RED  := $(shell tput setaf 1 2>/dev/null)
GRN  := $(shell tput setaf 2 2>/dev/null)
YEL  := $(shell tput setaf 3 2>/dev/null)
RST  := $(shell tput sgr0 2>/dev/null)

# Read the selected profile without sourcing .env — it contains quoted
# multi-word values (INFINITY_CMD), and sourcing it to learn one variable has
# already aborted a deploy once with `--model-id: command not found`.
PROFILE_NAME = $(shell sed -n 's/^SERVER_PROFILE=//p' .env 2>/dev/null | tail -1)
PROFILE_FILE = servers/server-$(PROFILE_NAME).env

# Which compose profiles to activate, derived from the server profile's
# ENABLE_* flags. A service the profile did not ask for is never started.
define enabled_profiles
$(shell set -a; for f in $$(./scripts/profile-files.sh 2>/dev/null); do . "$$f"; done; set +a; \
  p=""; \
  [ "$${ENABLE_VLLM:-false}"       = "true" ] && p="$$p --profile vllm"; \
  [ "$${ENABLE_VLLM2:-false}"      = "true" ] && p="$$p --profile vllm2"; \
  [ "$${ENABLE_VLLM3:-false}"      = "true" ] && p="$$p --profile vllm3"; \
  if [ "$${ENABLE_VLLM:-false}" = "true" ]; then \
    _router="$${ENABLE_VLLM_ROUTER:-true}"; \
    if [ "$${ENABLE_VLLM2:-false}" = "true" ] || [ "$${ENABLE_VLLM3:-false}" = "true" ]; then \
      _router=true; \
    fi; \
    [ "$$_router" = "true" ] && p="$$p --profile vllm-router"; \
  fi; \
  [ "$${ENABLE_LLAMACPP:-false}"   = "true" ] && p="$$p --profile llamacpp"; \
  [ "$${ENABLE_OLLAMA:-false}"     = "true" ] && p="$$p --profile ollama"; \
  [ "$${ENABLE_INFINITY:-false}"   = "true" ] && p="$$p --profile infinity"; \
  [ "$${ENABLE_EMBEDDINGS:-false}" = "true" ] && p="$$p --profile embeddings"; \
  [ "$${ENABLE_STT:-false}"       = "true" ] && p="$$p --profile stt"; \
  echo "$$p")
endef

.PHONY: help setup start stop restart status logs health models urls \
        check pull build clean versions model-store watchdog set-passwd create-key _require_profile

help:
	@printf "$(BOLD)gpu-inference-stack$(RST)\n\n"
	@printf "  $(BOLD)make setup$(RST)    detect this server, confirm, apply its profile,\n"
	@printf "                check prerequisites, pull images, build\n"
	@printf "  $(BOLD)make start$(RST)    start what the profile declares, then report\n"
	@printf "                models served and access URLs\n\n"
	@printf "  make stop     stop + remove containers   make restart  stop + start\n"
	@printf "  make status   containers + GPU       make health   full health check\n"
	@printf "  make models   what is served now     make urls     endpoints\n"
	@printf "  make logs     tail all logs             make check    prerequisites only\n"
	@printf "  make versions configured vs running images\n"
	@printf "  $(BOLD)make model-store$(RST) shared NAS checkpoint store $(DIM)(ARGS=sync|list|status)$(RST)\n"
	@printf "  $(BOLD)make watchdog$(RST)     install/enable the host watchdog timer + lingering\n"
	@printf "  $(BOLD)make set-passwd$(RST)   set LiteLLM UI credentials $(DIM)(stored encrypted in .env.secrets)$(RST)\n"
	@printf "  $(BOLD)make create-key$(RST)   generate a virtual API key for a consumer app\n"
	@printf "  $(DIM)make clean    also removes volumes (keys, dashboards) — asks first$(RST)\n\n"
	@printf "  $(DIM)Override detection:  make setup PROFILE=85$(RST)\n"
	@printf "  $(DIM)AUTO=1       take the default answer to every prompt$(RST)\n"
	@printf "  $(DIM)REBUILD=1    rebuild, reusing the Docker layer cache$(RST)\n"
	@printf "  $(DIM)NO_CACHE=1   like REBUILD but ignore the cache$(RST)\n"
	@printf "  $(DIM)SKIP_BUILD=1 skip the build$(RST)\n"
	@printf "  $(DIM)  SKIP_PREFLIGHT=1      skip pre-flight checks before start$(RST)\n"
	@printf "  $(DIM)  PREFLIGHT_STRICT=1    treat warnings as errors$(RST)\n"
	@printf "  $(DIM)  PREFLIGHT_NO_AUTOFIX=1 show fixes but don't apply them$(RST)\n"
	@printf "  $(DIM)Ad-hoc compose:      ./scripts/dc.sh ps$(RST)\n\n"
	@if [ -n "$(PROFILE_NAME)" ]; then \
	  printf "  Active profile: $(BOLD)$(PROFILE_NAME)$(RST)  $(DIM)($(PROFILE_FILE))$(RST)\n\n"; \
	else \
	  printf "  $(YEL)No profile selected yet — run 'make setup'.$(RST)\n\n"; fi

_require_profile:
	@if [ -z "$(PROFILE_NAME)" ]; then \
	  printf "$(RED)No SERVER_PROFILE set in .env.$(RST) Run $(BOLD)make setup$(RST) first.\n"; exit 1; fi
	@if [ ! -f "$(PROFILE_FILE)" ]; then \
	  printf "$(RED)SERVER_PROFILE=$(PROFILE_NAME) but $(PROFILE_FILE) does not exist.$(RST)\n"; \
	  printf "Available:\n"; ls -1 servers/server-*.env | sed 's|servers/server-\(.*\)\.env|  \1|'; exit 1; fi

# ---------------------------------------------------------------------------
setup:
	@printf "$(BOLD)1/7  Which server is this?$(RST)\n"
	@set -e; \
	prof="$(PROFILE)"; \
	if [ -z "$$prof" ]; then prof="$$(./scripts/detect-server.sh || true)"; fi; \
	if [ -z "$$prof" ]; then \
	  printf "\n$(RED)Could not detect this server.$(RST)\n"; \
	  printf "Pick one explicitly:  $(BOLD)make setup PROFILE=<name>$(RST)\n\nAvailable:\n"; \
	  ls -1 servers/server-*.env | sed 's|servers/server-\(.*\)\.env|  \1|'; exit 1; fi; \
	f="servers/server-$$prof.env"; \
	[ -f "$$f" ] || { printf "$(RED)No such profile: $$f$(RST)\n"; exit 1; }; \
	set -a; for g in $$(SERVER_PROFILE="$$prof" ./scripts/profile-files.sh 2>/dev/null); do . "$$g"; done; set +a; \
	printf "\n  detected  $(BOLD)%s$(RST)  $(DIM)(%s)$(RST)\n" "$$prof" "$$f"; \
	printf "  host      %s / %s\n" "$$(hostname -s)" "$$(hostname -I | awk '{print $$1}')"; \
	printf "  name      %s\n" "$${SERVER_NAME:-?}"; \
	printf "  gpu       %s\n" "$$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo 'none detected')"; \
	printf "  chat      %s\n" "$${VLLM_MODEL:-$${LLAMACPP_MODEL_FILE:-none}}"; \
	printf "  serves as %s  ctx %s  util %s\n" "$${VLLM_MODEL_NAME:-$${LLAMACPP_MODEL_NAME:-?}}" "$${VLLM_MAX_MODEL_LEN:-?}" "$${VLLM_GPU_MEMORY_UTILIZATION:-?}"; \
	printf "  gateway   %s:%s\n" "$${LITELLM_BIND_ADDR:-0.0.0.0}" "$${LITELLM_PORT:-8080}"; \
	printf "  services  vllm=%s vllm2=%s llamacpp=%s ollama=%s infinity=%s tei=%s\n" \
	   "$${ENABLE_VLLM:-false}" "$${ENABLE_VLLM2:-false}" "$${ENABLE_LLAMACPP:-false}" \
	   "$${ENABLE_OLLAMA:-false}" "$${ENABLE_INFINITY:-false}" "$${ENABLE_EMBEDDINGS:-false}"; \
	printf "\n"; \
	if [ "$(AUTO)" = "1" ]; then \
	  printf "  $(DIM)AUTO=1 — taking the default (apply)$(RST)\n"; \
	else \
	  if [ ! -t 0 ]; then printf "$(RED)Not a terminal and AUTO=1 not set — refusing to guess.$(RST)\n"; exit 1; fi; \
	  read -r -p "  Apply this profile? [Y/n] " a; \
	  case "$$a" in ""|y|Y|yes|YES) ;; *) printf "  aborted\n"; exit 1;; esac; \
	fi; \
	if [ ! -f .env ]; then cp .env.example .env; printf "\n  created .env from .env.example\n"; fi; \
	if grep -q '^SERVER_PROFILE=' .env; then \
	  sed -i "s|^SERVER_PROFILE=.*|SERVER_PROFILE=$$prof|" .env; \
	else printf 'SERVER_PROFILE=%s\n' "$$prof" >> .env; fi; \
	printf "  $(GRN)✓$(RST) .env now selects profile $(BOLD)%s$(RST)\n" "$$prof"; \
	if ! ./scripts/check-env-overrides.sh; then \
	  printf "\n$(YEL)⚠  Fix the overrides above before continuing.$(RST)\n"; \
	  printf "$(DIM)They defeat profile selection. Or bypass: SKIP_ENV_CHECK=1 make setup$(RST)\n"; \
	  [ "$(SKIP_ENV_CHECK)" = "1" ] || exit 1; fi
	@printf "\n$(BOLD)2/7  Prerequisites$(RST)\n"
	@$(MAKE) --no-print-directory check
	@printf "\n$(BOLD)3/7  Contract wiring$(RST)\n"
	@./scripts/check-contract-wiring.sh
	@printf "\n$(BOLD)4/7  Pulling images$(RST)  $(DIM)(--ignore-buildable: litellm is built locally)$(RST)\n"
	@$(DC) $(enabled_profiles) pull --ignore-buildable
	@printf "\n$(BOLD)5/7  Building local images$(RST)\n"
	@$(MAKE) --no-print-directory build
	@printf "\n$(BOLD)6/7  Models$(RST)  $(DIM)(shared NAS store first, Hugging Face only as a fallback)$(RST)\n"
	@./scripts/model-store.sh sync || printf "  $(YEL)! model sync incomplete — vLLM will fetch what is missing at start$(RST)\n"
	@printf "\n$(BOLD)7/7  Host watchdog$(RST)  $(DIM)(restarts an engine Docker reports unhealthy)$(RST)\n"
	@./scripts/install-watchdog.sh || printf "  $(YEL)! watchdog not fully installed — see the lines above$(RST)\n"
	@printf "\n$(BOLD)Resolved image versions$(RST)  $(DIM)(what you will actually run)$(RST)\n"
	@$(MAKE) --no-print-directory versions
	@printf "\n$(GRN)$(BOLD)Setup complete.$(RST)  Run $(BOLD)make start$(RST)\n"

# ---------------------------------------------------------------------------
## watchdog: install/enable the host watchdog timer (user systemd unit) and
##   turn on lingering so it survives logout and starts at boot. Run by
##   `make setup` step 7/7; idempotent, so re-run it after editing the units.
watchdog:
	@./scripts/install-watchdog.sh

# ---------------------------------------------------------------------------
## model-store: the shared NAS checkpoint store — status | sync | list |
##   publish <repo> | fetch <repo>. `sync` is what `make setup` runs: it puts
##   every model the profile names into the local cache, taking it from the NAS
##   when it is there and publishing it back when it is not, so the first box to
##   need a checkpoint is the only one that downloads it.
model-store: _require_profile
	@./scripts/model-store.sh $(or $(ARGS),status)

# ---------------------------------------------------------------------------
## set-passwd: set LiteLLM UI credentials in SOPS-encrypted .env.secrets
##   Prompts for username (default: admin) and password, then encrypts them.
##   The litellm container reads UI_USERNAME and UI_PASSWORD from here.
set-passwd:
	@if [ ! -f .age-key.txt ]; then \
	  printf "$(RED)No .age-key.txt found.$(RST) See docs/SECRETS.md for setup.\n"; exit 1; fi
	@printf "$(BOLD)Set LiteLLM UI credentials$(RST)\n\n"
	@printf "  These are stored encrypted in .env.secrets and passed to the\n"
	@printf "  litellm container as UI_USERNAME and UI_PASSWORD.\n\n"
	@read -r -p "  Username [admin]: " user; user="$${user:-admin}"; \
	 printf "  Password: "; stty -echo; read -r pass; stty echo; printf "\n"; \
	 if [ -z "$$pass" ]; then printf "  $(RED)Password cannot be empty.$(RST)\n"; exit 1; fi; \
	 export SOPS_AGE_KEY_FILE="$$(pwd)/.age-key.txt"; \
	 plain=$$(sops -d .env.secrets 2>/dev/null || echo ""); \
	 plain=$$(printf '%s\n' "$$plain" | grep -v '^UI_USERNAME=' | grep -v '^UI_PASSWORD=' | grep -v '^$$'); \
	 printf '%s\n\n# LiteLLM UI credentials\nUI_USERNAME=%s\nUI_PASSWORD=%s\n' "$$plain" "$$user" "$$pass" > .env.secrets.plain; \
	 sops -e .env.secrets.plain > .env.secrets; \
	 rm -f .env.secrets.plain; \
	 printf "\n  $(GRN)✓$(RST) Credentials saved to .env.secrets\n"; \
	 printf "  $(DIM)Run 'make restart' to apply changes.$(RST)\n"

# ---------------------------------------------------------------------------
## create-key: generate a LiteLLM virtual API key for a consumer application
##   Prompts for key alias and model access, confirms, then creates the key.
##   The generated key is what consumers use to authenticate with the gateway.
create-key: _require_profile
	@set -a; for f in $$(./scripts/profile-files.sh 2>/dev/null); do . "$$f"; done; set +a; \
	 port="$${LITELLM_PORT:-8080}"; \
	 master="$${LITELLM_MASTER_KEY:-sk-1234567890abcdef}"; \
	 host="$${LITELLM_BIND_ADDR:-127.0.0.1}"; [ "$$host" = "0.0.0.0" ] && host="127.0.0.1"; \
	 printf "$(BOLD)Create LiteLLM Virtual API Key$(RST)\n\n"; \
	 printf "  This generates an API key for a consumer application.\n"; \
	 printf "  The key grants access to specific models through the gateway.\n\n"; \
	 printf "$(BOLD)Available contract models:$(RST)\n"; \
	 printf "  $(DIM)1$(RST) gpu/chat/interactive  $(DIM)— tool-calling, >=32k ctx, JSON mode$(RST)\n"; \
	 printf "  $(DIM)2$(RST) gpu/chat/bulk         $(DIM)— tool-calling, >=32k ctx, JSON mode$(RST)\n"; \
	 printf "  $(DIM)3$(RST) gpu/chat/fast         $(DIM)— tool-calling, >=16k ctx, low latency$(RST)\n"; \
	 printf "  $(DIM)4$(RST) gpu/chat/vision       $(DIM)— image input (if available)$(RST)\n"; \
	 printf "  $(DIM)5$(RST) gpu/embed/bge-m3      $(DIM)— embeddings, 1024-dim$(RST)\n"; \
	 printf "  $(DIM)6$(RST) gpu/rerank/bge-reranker-v2-m3 $(DIM)— cross-encoder reranking$(RST)\n"; \
	 printf "  $(DIM)7$(RST) gpu/stt/whisper       $(DIM)— speech-to-text (if available)$(RST)\n"; \
	 printf "\n"; \
	 read -r -p "  Key alias (e.g. myapp, backend-prod): " alias; \
	 if [ -z "$$alias" ]; then printf "  $(RED)Alias cannot be empty.$(RST)\n"; exit 1; fi; \
	 printf "\n  Which models? Enter numbers separated by spaces, or:\n"; \
	 printf "    $(DIM)chat$(RST)  = 1 2 3 (all chat models)\n"; \
	 printf "    $(DIM)all$(RST)   = 1 2 3 4 5 6 7 (everything)\n"; \
	 printf "    $(DIM)Enter$(RST) = 1 2 3 (default: chat models)\n\n"; \
	 read -r -p "  Models [chat]: " model_input; \
	 model_input="$${model_input:-chat}"; \
	 models=""; \
	 case "$$model_input" in \
	   chat) models='["gpu/chat/interactive","gpu/chat/bulk","gpu/chat/fast"]';; \
	   all)  models='["gpu/chat/interactive","gpu/chat/bulk","gpu/chat/fast","gpu/chat/vision","gpu/embed/bge-m3","gpu/rerank/bge-reranker-v2-m3","gpu/stt/whisper"]';; \
	   *) \
	     for n in $$model_input; do \
	       case "$$n" in \
	         1) models="$$models\"gpu/chat/interactive\",";; \
	         2) models="$$models\"gpu/chat/bulk\",";; \
	         3) models="$$models\"gpu/chat/fast\",";; \
	         4) models="$$models\"gpu/chat/vision\",";; \
	         5) models="$$models\"gpu/embed/bge-m3\",";; \
	         6) models="$$models\"gpu/rerank/bge-reranker-v2-m3\",";; \
	         7) models="$$models\"gpu/stt/whisper\",";; \
	         *) printf "  $(YEL)Unknown model number: $$n$(RST)\n";; \
	       esac; \
	     done; \
	     models="[$${models%,}]";; \
	 esac; \
	 if [ "$$models" = "[]" ]; then printf "  $(RED)No valid models selected.$(RST)\n"; exit 1; fi; \
	 printf "\n$(BOLD)Summary$(RST)\n"; \
	 printf "  Alias:  $(BOLD)%s$(RST)\n" "$$alias"; \
	 printf "  Models: %s\n" "$$models"; \
	 printf "\n"; \
	 read -r -p "  Create this key? [Y/n] " confirm; \
	 case "$$confirm" in ""|y|Y|yes|YES) ;; *) printf "  Aborted.\n"; exit 0;; esac; \
	 printf "\n  Creating key...\n"; \
	 resp=$$(curl -s -X POST "http://$$host:$$port/key/generate" \
	   -H "Authorization: Bearer $$master" \
	   -H "Content-Type: application/json" \
	   -d "{\"key_alias\":\"$$alias\",\"models\":$$models}" 2>&1); \
	 if printf '%s' "$$resp" | grep -q '"key"'; then \
	   key=$$(printf '%s' "$$resp" | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'); \
	   printf "\n  $(GRN)$(BOLD)✓ Key created successfully$(RST)\n\n"; \
	   printf "  $(BOLD)API Key:$(RST) %s\n\n" "$$key"; \
	   printf "  $(DIM)Store this key securely — it cannot be retrieved later.$(RST)\n"; \
	   printf "  $(DIM)Consumers use it as: Authorization: Bearer %s$(RST)\n" "$$key"; \
	 else \
	   printf "\n  $(RED)✗ Failed to create key$(RST)\n"; \
	   printf "  %s\n" "$$resp"; \
	   printf "\n  $(DIM)Is the gateway running? Try: make status$(RST)\n"; \
	   exit 1; \
	 fi

# ---------------------------------------------------------------------------
check: _require_profile
	@set -e; ok=1; \
	command -v docker >/dev/null   && printf "  $(GRN)✓$(RST) docker %s\n" "$$(docker --version | awk '{print $$3}' | tr -d ,)" || { printf "  $(RED)✗$(RST) docker not installed\n"; ok=0; }; \
	docker compose version >/dev/null 2>&1 && printf "  $(GRN)✓$(RST) compose %s\n" "$$(docker compose version --short)" || { printf "  $(RED)✗$(RST) docker compose v2 missing\n"; ok=0; }; \
	docker info >/dev/null 2>&1    && printf "  $(GRN)✓$(RST) docker daemon reachable\n" || { printf "  $(RED)✗$(RST) cannot reach the docker daemon\n"; ok=0; }; \
	if command -v nvidia-smi >/dev/null; then \
	  printf "  $(GRN)✓$(RST) gpu %s\n" "$$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"; \
	  free=$$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1); \
	  printf "  $(DIM)  %s MiB free of %s MiB$(RST)\n" "$$free" "$$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"; \
	else printf "  $(RED)✗$(RST) nvidia-smi not found\n"; ok=0; fi; \
	docker run --rm --gpus all ubuntu:22.04 true >/dev/null 2>&1 \
	  && printf "  $(GRN)✓$(RST) nvidia container runtime works\n" \
	  || printf "  $(YEL)!$(RST) could not run a --gpus container (nvidia-container-toolkit?)\n"; \
	set -a; for f in $$(./scripts/profile-files.sh 2>/dev/null); do . "$$f"; done; set +a; \
	for spec in "$${LITELLM_PORT:-8080}:gateway" "$${VLLM_PORT:-8100}:vllm" \
	            "$${INFINITY_PORT:-7997}:infinity" "$${OLLAMA_PORT:-11434}:ollama"; do \
	  port="$${spec%%:*}"; what="$${spec##*:}"; \
	  case "$$what" in \
	    vllm)     [ "$${ENABLE_VLLM:-false}" = "true" ] || continue;; \
	    infinity) [ "$${ENABLE_INFINITY:-false}" = "true" ] || continue;; \
	    ollama)   [ "$${ENABLE_OLLAMA:-false}" = "true" ] || continue;; \
	  esac; \
	  holder=$$(ss -ltnpH "sport = :$$port" 2>/dev/null | head -1); \
	  if [ -n "$$holder" ]; then \
	    mine=$$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E ":$$port->" | awk '{print $$1}' | head -1); \
	    if [ -n "$$mine" ]; then printf "  $(GRN)✓$(RST) port %-6s held by our own container (%s)\n" "$$port" "$$mine"; \
	    else printf "  $(YEL)!$(RST) port %-6s (%s) already in use by something else\n" "$$port" "$$what"; \
	         printf "  $(DIM)    %s$(RST)\n" "$$(printf '%s' "$$holder" | sed 's/.*users://')"; fi; \
	  else printf "  $(GRN)✓$(RST) port %-6s free (%s)\n" "$$port" "$$what"; fi; \
	done; \
	avail=$$(df -BG --output=avail "$(ROOT)" 2>/dev/null | tail -1 | tr -dc '0-9'); \
	if [ -n "$$avail" ] && [ "$$avail" -lt 60 ]; then \
	  printf "  $(YEL)!$(RST) only %sG free here — model weights are tens of GB\n" "$$avail"; \
	else printf "  $(GRN)✓$(RST) disk %sG free\n" "$$avail"; fi; \
	[ "$$ok" = "1" ] || { printf "\n$(RED)Prerequisites not met.$(RST)\n"; exit 1; }

# ---------------------------------------------------------------------------
start: _require_profile
	@printf "$(BOLD)Starting$(RST) $(DIM)profile $(PROFILE_NAME)$(RST)\n"
	@# Run pre-flight checks (auto-fixes where possible)
	@if [ "$(SKIP_PREFLIGHT)" != "1" ]; then \
	  PREFLIGHT_SERVICES="$$($(DC) $(enabled_profiles) config --services 2>/dev/null | tr '\n' ' ')" \
	    ./scripts/preflight-checks.sh || exit 1; \
	fi
	@# Check for .env overrides that shadow profile settings. This catches the
	@# case where .env has VLLM_MAX_MODEL_LEN=16384 while the profile says 65536,
	@# and the container gets 16384 because .env loads last and wins.
	@if ! ./scripts/check-env-overrides.sh; then \
	  printf "\n$(YEL)Fix the overrides above, then re-run make start.$(RST)\n"; \
	  printf "$(DIM)Or ignore this check with: SKIP_ENV_CHECK=1 make start$(RST)\n\n"; \
	  [ "$(SKIP_ENV_CHECK)" = "1" ] || exit 1; fi
	@$(DC) $(enabled_profiles) up -d
	@# A container left behind by a profile this box no longer enables is still
	@# part of the compose project, so it shows in `ps` and would otherwise gate
	@# the health wait forever on a service the profile does not even want.
	@svcs="$$($(DC) $(enabled_profiles) config --services 2>/dev/null | tr '\n' '|' | sed 's/|$$//')"; \
	 orph=$$($(DC) $(enabled_profiles) ps --format '{{.Service}} {{.Name}}' 2>/dev/null \
	   | awk -v w="^($$svcs)$$" '$$1 !~ w {print $$2}' | tr '\n' ' '); \
	 if [ -n "$$orph" ]; then \
	   printf "  $(YEL)!$(RST) left over from a profile this box no longer enables: %s\n" "$$orph"; \
	   printf "  $(DIM)  not waited on and not touched. Clear with: make stop$(RST)\n"; fi
	@printf "\n  waiting for health $(DIM)(a cold vLLM loads tens of GB; several minutes is normal)$(RST)\n"
	@set -e; deadline=$$(( $$(date +%s) + 900 )); \
	want="$$($(DC) $(enabled_profiles) config --services 2>/dev/null | tr '\n' '|' | sed 's/|$$//')"; \
	while :; do \
	  st=$$($(DC) $(enabled_profiles) ps --format '{{.Service}} {{.Name}} {{.State}} {{.Health}}' 2>/dev/null \
	        | awk -v w="^($$want)$$" '$$1 ~ w'); \
	  bad=$$(printf '%s\n' "$$st" | awk '$$3=="running" && $$4!="" && $$4!="healthy" {print $$2}' | tr '\n' ' '); \
	  dead=$$(printf '%s\n' "$$st" | awk '$$3=="exited"||$$3=="dead" {print $$2}' | tr '\n' ' '); \
	  if [ -n "$$dead" ]; then printf "  $(RED)✗ exited:$(RST) %s\n" "$$dead"; \
	    for c in $$dead; do printf "$(DIM)--- %s ---$(RST)\n" "$$c"; docker logs --tail 20 "$$c" 2>&1 | tail -20; done; exit 1; fi; \
	  [ -z "$$bad" ] && break; \
	  [ $$(date +%s) -ge $$deadline ] && { printf "  $(YEL)! still starting after 15m:$(RST) %s\n" "$$bad"; break; }; \
	  sleep 10; \
	done; \
	printf "  $(GRN)✓$(RST) all containers healthy\n"
	@# Consumer keys need /capacity in their metadata or LiteLLM answers 403 and
	@# every consumer sizes blind (README "Load"). Idempotent; never fails start.
	@python3 scripts/grant-capacity-access.py --wait 120 --quiet \
	  || printf "  $(YEL)!$(RST) could not grant /capacity to consumer keys — run: python3 scripts/grant-capacity-access.py\n"
	@printf "\n"; $(MAKE) --no-print-directory models
	@printf "\n"; $(MAKE) --no-print-directory urls

models: _require_profile
	@set -a; for f in $$(./scripts/profile-files.sh 2>/dev/null); do . "$$f"; done; set +a; \
	printf "$(BOLD)Serving$(RST)\n"; \
	key="$${LITELLM_MASTER_KEY:-sk-1234567890abcdef}"; \
	port="$${LITELLM_PORT:-8080}"; \
	host="$${LITELLM_BIND_ADDR:-127.0.0.1}"; [ "$$host" = "0.0.0.0" ] && host="127.0.0.1"; \
	out=$$(curl -s -m 10 -H "Authorization: Bearer $$key" "http://$$host:$$port/v1/models" 2>/dev/null); \
	if [ -z "$$out" ] || printf '%s' "$$out" | grep -q '"error"'; then \
	  printf "  $(YEL)gateway not answering on :%s yet$(RST)\n" "$$port"; \
	else \
	  printf '%s' "$$out" | python3 -c 'import sys,json;\
d=json.load(sys.stdin);ids=[m["id"] for m in d.get("data",[])];\
c=[i for i in ids if i.startswith("gpu/")];u=[i for i in ids if i.startswith("unserved/")];\
l=[i for i in ids if not i.startswith(("gpu/","unserved/"))];\
print("  contract:");[print(f"    {i}") for i in c] or print("    (none)");\
print("  unserved (consumers fall back):") if u else None;[print(f"    {i}") for i in u];\
print(f"  legacy aliases: {len(l)}") if l else None' 2>/dev/null || printf "  (could not parse /v1/models)\n"; \
	fi; \
	printf "\n$(BOLD)Backends$(RST)\n"; \
	$(DC) $(enabled_profiles) ps --format '{{.Name}}\t{{.State}}\t{{.Health}}' 2>/dev/null \
	  | awk -F'\t' '{printf "  %-18s %-9s %s\n", $$1, $$2, ($$3==""?"-":$$3)}'; \
	if command -v nvidia-smi >/dev/null; then \
	  printf "\n  $(DIM)GPU %s MiB used of %s MiB$(RST)\n" \
	    "$$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)" \
	    "$$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"; fi

urls: _require_profile
	@set -a; for f in $$(./scripts/profile-files.sh 2>/dev/null); do . "$$f"; done; set +a; \
	host="$${LITELLM_BIND_ADDR:-0.0.0.0}"; \
	[ "$$host" = "0.0.0.0" ] && host="$$(hostname -I | awk '{print $$1}')"; \
	printf "$(BOLD)Endpoints$(RST)\n"; \
	printf "  gateway (consumers use this)  $(BOLD)http://%s:%s$(RST)\n" "$$host" "$${LITELLM_PORT:-8080}"; \
	printf "  $(DIM)models    http://%s:%s/v1/models$(RST)\n" "$$host" "$${LITELLM_PORT:-8080}"; \
	printf "  $(DIM)health    http://%s:%s/health/liveliness$(RST)\n" "$$host" "$${LITELLM_PORT:-8080}"; \
	[ "$${ENABLE_VLLM:-false}"     = "true" ] && printf "  vllm      http://%s:%s/v1\n" "$$host" "$${VLLM_PORT:-8100}" || true; \
	[ "$${ENABLE_VLLM2:-false}"    = "true" ] && printf "  vllm2     http://%s:%s/v1\n" "$$host" "$${VLLM2_PORT:-8010}" || true; \
	[ "$${ENABLE_LLAMACPP:-false}" = "true" ] && printf "  llamacpp  http://%s:%s/v1\n" "$$host" "$${LLAMACPP_PORT:-8083}" || true; \
	[ "$${ENABLE_INFINITY:-false}" = "true" ] && printf "  infinity  http://%s:%s\n"    "$$host" "$${INFINITY_PORT:-7997}" || true; \
	[ "$${ENABLE_OLLAMA:-false}"   = "true" ] && printf "  ollama    http://%s:%s\n"    "$$host" "$${OLLAMA_PORT:-11434}" || true; \
	printf "\n  $(DIM)A consumer needs a VIRTUAL key, not the master key:$(RST)\n"; \
	printf "  $(DIM)curl -X POST http://%s:%s/key/generate -H \"Authorization: Bearer \$$LITELLM_MASTER_KEY\" \\$(RST)\n" "$$host" "$${LITELLM_PORT:-8080}"; \
	printf "  $(DIM)  -H 'Content-Type: application/json' -d '{\"key_alias\":\"<app>\",\"models\":[\"gpu/chat/bulk\"]}'$(RST)\n"
# "Configured" is what the active profile asks for; "running" is what the
# container was actually created from. They diverge the moment a profile pins a
# new version and nothing has restarted yet — precisely the state a version
# bump leaves you in, and `docker ps` does not show it.
versions: _require_profile
	@$(DC) $(enabled_profiles) config --format json 2>/dev/null | ./scripts/versions.py

# ---------------------------------------------------------------------------
stop: _require_profile
	@# `--profile "*"` enables EVERY profile, which is what makes this stop
	@# everything the project owns. --remove-orphans alone is not enough: a
	@# service that IS defined in docker-compose.yml but whose profile is
	@# disabled is not an orphan, so `down` skips it and it keeps running (and
	@# keeps holding VRAM). That is exactly how a leftover ollama container
	@# survived a stop on this box and then blocked `make start`.
	@$(DC) --profile "*" down --remove-orphans
	@left=$$(docker ps -a --filter "label=com.docker.compose.project=$$(basename $(ROOT))" --format '{{.Names}}' | tr '\n' ' '); \
	 if [ -n "$$left" ]; then printf "  $(YEL)!$(RST) still present: %s\n" "$$left"; \
	 else printf "  $(GRN)✓$(RST) containers stopped and removed $(DIM)(volumes and data/ kept)$(RST)\n"; fi
	@command -v nvidia-smi >/dev/null && printf "  $(DIM)GPU now %s MiB used of %s MiB$(RST)\n" \
	   "$$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)" \
	   "$$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)" || true

# Destructive, and separate from `stop` for that reason: this removes the named
# volumes too — Postgres (LiteLLM's virtual keys and spend history), Grafana
# dashboards, Redis cache. Model weights under data/ are bind mounts and are
# NOT touched, so a rebuild does not re-download tens of GB.
clean: _require_profile
	@printf "$(RED)$(BOLD)This removes containers AND named volumes.$(RST)\n"
	@printf "  Lost: LiteLLM's Postgres (virtual keys, spend history), Grafana, Redis.\n"
	@printf "  Kept: model weights and anything else under data/.\n\n"
	@if [ "$(AUTO)" = "1" ]; then \
	  printf "  $(YEL)AUTO=1 takes the default, and the default here is NO.$(RST)\n"; \
	  printf "  $(DIM)Destroying keys and spend history is not something an unattended$(RST)\n"; \
	  printf "  $(DIM)run should be able to do. Re-run interactively, or FORCE=1.$(RST)\n"; \
	  [ "$(FORCE)" = "1" ] || exit 1; \
	  printf "  $(RED)FORCE=1 — proceeding$(RST)\n"; \
	elif [ "$(FORCE)" != "1" ]; then \
	  read -r -p "  Type 'yes' to continue: " a; [ "$$a" = "yes" ] || { printf "  aborted\n"; exit 1; }; fi
	@$(DC) --profile "*" down --remove-orphans --volumes
	@printf "  $(GRN)✓$(RST) containers and volumes removed\n"

restart: stop start

status: _require_profile
	@$(DC) $(enabled_profiles) ps
	@command -v nvidia-smi >/dev/null && printf "\n" && nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv || true

logs: _require_profile
	@$(DC) $(enabled_profiles) logs -f --tail 100

health: _require_profile
	@./scripts/health-check.sh

pull: _require_profile
	@$(DC) $(enabled_profiles) pull --ignore-buildable

# Folded into `setup`, and forceable on its own — the workspace convention:
#   (bare)        build only when it is actually needed
#   REBUILD=1     rebuild, reusing the Docker layer cache
#   NO_CACHE=1    like REBUILD but ignore the cache (--no-cache --pull)
#   SKIP_BUILD=1  skip the build entirely
#
# "Needed" means the image is missing, or the build context has changed since
# it was built. The stamp is a hash of config/litellm/, so editing the
# Dockerfile triggers a rebuild without anyone having to remember REBUILD=1 —
# the failure that flag exists to work around elsewhere.
#
# --pull is ALWAYS passed when building. The base is `main-latest`, which is
# mutable: without it, `build` reuses a cached FROM layer and an apparently
# successful build hands you a month-old litellm. A pinned base would not need
# this; a mutable one always does.
BUILD_STAMP := .docker-build-hash
build_ctx_hash = $(shell find config/litellm -type f 2>/dev/null | sort | xargs sha1sum 2>/dev/null | sha1sum | cut -c1-16)

build: _require_profile
	@if [ "$(SKIP_BUILD)" = "1" ]; then printf "  $(DIM)skipped (SKIP_BUILD=1)$(RST)\n"; exit 0; fi; \
	 want="$(build_ctx_hash)"; have="$$(cat $(BUILD_STAMP) 2>/dev/null || true)"; \
	 have_img=$$(docker image inspect gpu-inference-stack-litellm:latest >/dev/null 2>&1 && echo yes || echo no); \
	 if [ "$(NO_CACHE)" = "1" ]; then why="NO_CACHE=1"; flags="--pull --no-cache"; \
	 elif [ "$(REBUILD)" = "1" ]; then why="REBUILD=1"; flags="--pull"; \
	 elif [ "$$have_img" = "no" ]; then why="image missing"; flags="--pull"; \
	 elif [ "$$want" != "$$have" ]; then why="build context changed"; flags="--pull"; \
	 else printf "  $(GRN)✓$(RST) image up to date $(DIM)(context unchanged — force with REBUILD=1)$(RST)\n"; exit 0; fi; \
	 printf "  building $(DIM)(%s)$(RST)\n" "$$why"; \
	 $(DC) $(enabled_profiles) build $$flags; \
	 printf '%s' "$$want" > $(BUILD_STAMP)
