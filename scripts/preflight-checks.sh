#!/usr/bin/env bash
# Pre-flight checks for make start
# Auto-fixes common issues, warns on others, halts on critical failures

set -euo pipefail

# Import color codes (same pattern as Makefile)
BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
GRN=$(tput setaf 2 2>/dev/null || true)
YEL=$(tput setaf 3 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)

# Configuration from environment
STRICT=${PREFLIGHT_STRICT:-0}
NO_AUTOFIX=${PREFLIGHT_NO_AUTOFIX:-0}
AUTO=${AUTO:-0}

# Return codes: 0=pass, 1=warning, 2=critical error

# Helper: Show error box for critical failures
show_error_box() {
    local title="$1"
    local message="$2"
    local remediation="$3"

    local width=61
    local border_top="┌─────────────────────────────────────────────────────────┐"
    local border_mid="├─────────────────────────────────────────────────────────┤"
    local border_bot="└─────────────────────────────────────────────────────────┘"

    printf "\n%s\n" "$border_top"
    printf "│ ${RED}✗${RST} %-53s │\n" "$title"
    printf "%s\n" "$border_mid"
    printf "│ %-57s │\n" ""

    # Print message lines
    while IFS= read -r line; do
        printf "│ %-57s │\n" "$line"
    done <<< "$message"

    printf "│ %-57s │\n" ""

    if [ -n "$remediation" ]; then
        printf "│ ${BOLD}To fix:${RST}%-49s │\n" ""
        while IFS= read -r line; do
            printf "│   %-55s │\n" "$line"
        done <<< "$remediation"
        printf "│ %-57s │\n" ""
    fi

    printf "%s\n\n" "$border_bot"
}

# Helper: Get compose project name
get_compose_project() {
    basename "$(pwd)"
}

# _runs_service <container> — is it a service the active profile runs?
# PREFLIGHT_SERVICES is the Makefile's `compose config --services` for the
# enabled profiles; unset (a direct run of this script) means none, i.e. every
# holder of ours is treated as a leftover, as before.
_runs_service() {
    local svc
    [ -n "${PREFLIGHT_SERVICES:-}" ] || return 1
    svc="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$1" 2>/dev/null)"
    [ -n "$svc" ] && case " $PREFLIGHT_SERVICES " in *" $svc "*) true ;; *) false ;; esac
}

# Helper: Get ports needed by active profile
get_required_ports() {
    # Source profile files to get port configuration
    local ports=""

    # Always check LiteLLM and base services
    ports="${LITELLM_PORT:-8080} ${REDIS_PORT:-6390} ${PROMETHEUS_PORT:-9090} ${GRAFANA_PORT:-3000}"

    # Check enabled services from environment
    [ "${ENABLE_VLLM:-false}" = "true" ] && ports="$ports ${VLLM_PORT:-8100}"
    [ "${ENABLE_VLLM2:-false}" = "true" ] && ports="$ports ${VLLM2_PORT:-8010}"
    [ "${ENABLE_VLLM3:-false}" = "true" ] && ports="$ports ${VLLM3_PORT:-8011}"
    [ "${ENABLE_OLLAMA:-false}" = "true" ] && ports="$ports ${OLLAMA_PORT:-11434}"
    [ "${ENABLE_LLAMACPP:-false}" = "true" ] && ports="$ports ${LLAMACPP_PORT:-8083}"
    [ "${ENABLE_INFINITY:-false}" = "true" ] && ports="$ports ${INFINITY_PORT:-7997}"
    [ "${ENABLE_EMBEDDINGS:-false}" = "true" ] && ports="$ports ${EMBEDDINGS_PORT:-8082}"

    echo "$ports" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# Helper: Name the variable that sets a required port, for the refusal message
port_var_for() {
    local v
    for v in LITELLM_PORT REDIS_PORT PROMETHEUS_PORT GRAFANA_PORT VLLM_PORT VLLM2_PORT \
             VLLM3_PORT OLLAMA_PORT LLAMACPP_PORT INFINITY_PORT EMBEDDINGS_PORT; do
        if [ "${!v:-}" = "$1" ]; then echo "$v"; return 0; fi
    done
    echo "<the *_PORT set to $1>"
}

# Check 1: Docker daemon responsive
check_docker_daemon() {
    if timeout 5 docker info >/dev/null 2>&1; then
        printf "  ${GRN}✓${RST} Docker daemon responsive\n"
        return 0
    else
        printf "  ${RED}✗${RST} Docker daemon not responding (timeout after 5s)\n"
        printf "    ${DIM}Is Docker running? Try: sudo systemctl start docker${RST}\n"
        return 2
    fi
}

# Check 2: Disk space >= 5GB free
check_disk_space() {
    local free_gb
    free_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')

    if [ "$free_gb" -ge 5 ]; then
        printf "  ${GRN}✓${RST} Disk space OK (${free_gb} GB free)\n"
        return 0
    else
        printf "  ${YEL}!${RST} Low disk space: ${free_gb} GB free (recommend 5GB+)\n"
        printf "    ${DIM}Suggestion: docker system prune -a${RST}\n"
        return 1
    fi
}

# Check 3: GPU available with reasonable free memory
check_gpu_availability() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf "  ${DIM}○${RST} GPU check skipped (nvidia-smi not found)\n"
        return 0
    fi

    local free_mb
    if ! free_mb=$(timeout 10 nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1); then
        printf "  ${YEL}!${RST} GPU check timed out (continuing anyway)\n"
        return 1
    fi

    if [ "$free_mb" -ge 500 ]; then
        printf "  ${GRN}✓${RST} GPU available (${free_mb} MB free)\n"
        return 0
    else
        printf "  ${YEL}!${RST} GPU memory low: ${free_mb} MB free\n"
        printf "    ${DIM}Current processes:${RST}\n"
        nvidia-smi pmon -c 1 2>/dev/null | grep -v '^#' | head -5 || true
        return 1
    fi
}

# Check 4: Container name conflicts (AUTO-FIX)
check_container_conflicts() {
    local project
    project=$(get_compose_project)

    # Get container names we care about from docker-compose.yml
    local our_containers
    our_containers="ollama|vllm-new|vllm2|vllm3|vllm-router-new|litellm|redis|postgres|prometheus|grafana|node-exporter|dcgm-exporter|redis-exporter|llamacpp|embeddings|infinity|nginx"

    # Find containers matching our names that aren't part of our compose project
    local conflicts
    conflicts=$(docker ps -a --format '{{.Names}}\t{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.CreatedAt}}' \
        | awk -F'\t' -v names="^($our_containers)$" -v proj="$project" '$1 ~ names && $3 != proj' || true)

    if [ -z "$conflicts" ]; then
        printf "  ${GRN}✓${RST} No container name conflicts\n"
        return 0
    fi

    # Auto-fix ONLY a leftover of this checkout (same compose working dir under
    # an older project name). The names above are generic — `redis`,
    # `grafana` — so a same-named container from another stack is refused,
    # never removed.
    local foreign=0
    while IFS=$'\t' read -r name id owner workdir created; do
        printf "  ${YEL}⚠${RST} Container name conflict: ${name} (${id:0:8}, created ${created})\n"

        if [ "$workdir" != "$PWD" ]; then
            printf "    ${RED}✗${RST} belongs to ${owner:-no compose project} (${workdir:-unknown dir}) — not ours, not removed\n"
            foreign=$((foreign + 1))
        elif [ "$NO_AUTOFIX" = "1" ]; then
            printf "    ${DIM}Would remove (PREFLIGHT_NO_AUTOFIX=1): docker rm -f ${name}${RST}\n"
        else
            printf "  ${DIM}→${RST} Removing conflicting container... "
            if docker rm -f "$name" >/dev/null 2>&1; then
                printf "done\n"
            else
                printf "failed\n"
                return 2
            fi
        fi
    done <<< "$conflicts"

    if [ "$foreign" -gt 0 ] || [ "$NO_AUTOFIX" = "1" ]; then
        return 2
    fi

    return 0
}

# Check 5: Port conflicts (CONDITIONAL AUTO-FIX)
check_port_conflicts() {
    # Source profile to get ENABLE_* flags
    set -a
    for f in $(./scripts/profile-files.sh 2>/dev/null); do
        [ -f "$f" ] && . "$f"
    done
    set +a

    local ports
    ports=$(get_required_ports)

    local conflicts=0
    local checked=0

    for port in $ports; do
        [ -z "$port" ] && continue
        checked=$((checked + 1))

        # Use ss (preferred) or fall back to lsof
        local listening
        if command -v ss >/dev/null 2>&1; then
            listening=$(ss -tlnp 2>/dev/null | grep ":$port " | head -1 || true)
        elif command -v lsof >/dev/null 2>&1; then
            listening=$(lsof -i ":$port" -sTCP:LISTEN 2>/dev/null | grep -v PID | head -1 || true)
        else
            printf "  ${YEL}!${RST} Port check skipped (neither ss nor lsof available)\n"
            return 1
        fi

        if [ -z "$listening" ]; then
            continue
        fi

        # Port is in use - find the container publishing it on the HOST side
        # (`addr:PORT->`). `--filter publish=` was not enough: it cannot tell
        # whose container it is, and on 2026-09-24 this stopped
        # platform-falkordb (deepdarshak's graph) as if it were ours.
        local holder container_using="" holder_project=""
        holder=$(docker ps --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}' 2>/dev/null \
            | awk -F'\t' -v p=":$port->" 'index($3, p) {print $1 "\t" $2; exit}' || true)
        if [ -n "$holder" ]; then
            container_using=${holder%%$'\t'*}
            holder_project=${holder#*$'\t'}
        fi

        if [ -n "$container_using" ] && [ "$holder_project" != "$(get_compose_project)" ]; then
            # Another stack's container. Never stop it — refuse and say who.
            show_error_box \
                "Pre-flight check failed: Port conflict" \
                "Port $port is held by container $container_using
  (project: ${holder_project:-none}) — not ours, not touched." \
                "Move our port in the server profile or .env:
   $(port_var_for "$port")=<free port>"
            conflicts=$((conflicts + 1))
        elif [ -n "$container_using" ] && _runs_service "$container_using"; then
            # A service this profile runs: `compose up -d` reconciles it, so a
            # healthy one keeps serving. Stopping it reloaded vLLM on every start.
            continue
        elif [ -n "$container_using" ]; then
            # Our leftover: a service this profile no longer runs
            printf "  ${YEL}⚠${RST} Port conflict: $port in use by $container_using (old container)\n"

            if [ "$NO_AUTOFIX" = "1" ]; then
                printf "    ${DIM}Would stop (PREFLIGHT_NO_AUTOFIX=1): docker stop $container_using${RST}\n"
                conflicts=$((conflicts + 1))
            else
                printf "  ${DIM}→${RST} Stopping old container... "
                if docker stop "$container_using" >/dev/null 2>&1; then
                    printf "done\n"
                else
                    printf "failed\n"
                    conflicts=$((conflicts + 1))
                fi
            fi
        else
            # External process - show error box
            local process_info
            if command -v lsof >/dev/null 2>&1; then
                process_info=$(sudo lsof -i ":$port" 2>/dev/null | grep LISTEN | awk '{print $1 " (PID " $2 ")"}' | head -1)
            else
                process_info="Unknown process"
            fi

            show_error_box \
                "Pre-flight check failed: Port conflict" \
                "Port $port is already in use by:
  $process_info" \
                "1. Stop the conflicting process:
   sudo kill <PID>

2. Or change the port in .env:
   LITELLM_PORT=$((port+1))

3. Or force start anyway (not recommended):
   SKIP_PREFLIGHT=1 make start"

            ((conflicts++))
        fi
    done

    if [ "$checked" -eq 0 ]; then
        printf "  ${DIM}○${RST} Port check skipped (no ports configured)\n"
        return 0
    fi

    if [ "$conflicts" -gt 0 ]; then
        return 2
    fi

    printf "  ${GRN}✓${RST} Ports available ($checked checked)\n"
    return 0
}

# Check 6: Docker Compose version
check_compose_version() {
    if ! command -v docker >/dev/null 2>&1; then
        printf "  ${RED}✗${RST} docker command not found\n"
        return 2
    fi

    local version
    if ! version=$(docker compose version --short 2>/dev/null); then
        printf "  ${YEL}!${RST} Could not determine Docker Compose version\n"
        return 1
    fi

    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)

    if [ "$major" -ge 2 ]; then
        printf "  ${GRN}✓${RST} Docker Compose ${version}\n"
        return 0
    else
        printf "  ${YEL}!${RST} Docker Compose ${version} is old (recommend 2.0+)\n"
        printf "    ${DIM}Install: https://docs.docker.com/compose/install/${RST}\n"
        return 1
    fi
}

# Check 7: Volume mount paths exist (AUTO-CREATE)
check_volume_paths() {
    # Source profile to get volume path variables
    set -a
    for f in $(./scripts/profile-files.sh 2>/dev/null); do
        [ -f "$f" ] && . "$f"
    done
    set +a

    local paths=(
        "${VLLM_CACHE_DIR:-./data/vllm/cache}"
        "${HF_HOME:-./data/huggingface}"
        "${OLLAMA_MODELS_DIR:-./data/ollama/models}"
        "${LLAMACPP_MODELS_DIR:-./data/llamacpp/models}"
        "./data/postgres"
        "./config/litellm"
        "./config/prometheus"
        "./config/grafana/provisioning"
        "./config/grafana/dashboards"
    )

    local created=0

    for path in "${paths[@]}"; do
        if [ ! -d "$path" ]; then
            if [ "$NO_AUTOFIX" = "1" ]; then
                printf "  ${YEL}⚠${RST} Missing directory: $path\n"
                printf "    ${DIM}Would create (PREFLIGHT_NO_AUTOFIX=1)${RST}\n"
            else
                mkdir -p "$path"
                printf "  ${DIM}→${RST} Created directory: $path\n"
                created=$((created + 1))
            fi
        fi
    done

    if [ "$created" -eq 0 ] && [ "$NO_AUTOFIX" != "1" ]; then
        printf "  ${GRN}✓${RST} Volume paths exist\n"
    fi

    return 0
}

# Check 8: Network conflicts (AUTO-FIX)
check_network_conflicts() {
    local network_name="${NETWORK_NAME:-gpu-inference-net}"

    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        printf "  ${GRN}✓${RST} Network will be created\n"
        return 0
    fi

    # Check if any running containers are using it
    local containers_using
    containers_using=$(docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)

    if [ -z "$containers_using" ]; then
        # Network exists but unused - remove it so compose can recreate with correct settings
        printf "  ${YEL}⚠${RST} Stale network found: $network_name\n"

        if [ "$NO_AUTOFIX" = "1" ]; then
            printf "    ${DIM}Would remove (PREFLIGHT_NO_AUTOFIX=1): docker network rm $network_name${RST}\n"
        else
            printf "  ${DIM}→${RST} Removing stale network... "
            if docker network rm "$network_name" >/dev/null 2>&1; then
                printf "done\n"
            else
                printf "failed\n"
                return 1
            fi
        fi
    else
        printf "  ${GRN}✓${RST} Network exists (used by: ${containers_using})\n"
    fi

    return 0
}

# Check 9: Required images available (INFO ONLY)
check_images_available() {
    # This is informational - compose will pull missing images
    # Just note if large images need pulling

    local images=(
        "${VLLM_IMAGE:-vllm/vllm-openai:v0.23.0}"
        "gpu-inference-stack-litellm:latest"
    )

    local missing=()

    for image in "${images[@]}"; do
        if ! docker images -q "$image" 2>/dev/null | grep -q .; then
            missing+=("$image")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf "  ${DIM}ℹ${RST} Will pull missing images:\n"
        for img in "${missing[@]}"; do
            printf "    ${DIM}$img${RST}\n"
        done
    fi

    return 0
}

# Reject absent/example gateway credentials without printing their contents.
check_credentials() (
    if [[ ! -v LITELLM_MASTER_KEY ]]; then
        set -a
        for f in $(./scripts/profile-files.sh 2>/dev/null); do . "$f"; done
        set +a
    fi
    local key="${LITELLM_MASTER_KEY:-}"
    case "${key,,}" in
        *change*|*example*|*placeholder*|sk-1234567890abcdef|empty)
            printf '  Gateway credential is a placeholder; set LITELLM_MASTER_KEY.\n'; return 2 ;;
    esac
    if [ "${#key}" -lt 24 ]; then
        printf '  Set LITELLM_MASTER_KEY to a random secret of at least 24 characters.\n'
        return 2
    fi
    printf '  Gateway credential configured.\n'
)

main() {
    printf "Running pre-flight checks...\n\n"

    local warnings=0
    local errors=0

    check_credentials || return 2

    # Tier 2 - Critical
    check_docker_daemon || errors=$((errors + 1))
    check_compose_version || warnings=$((warnings + 1))

    # Tier 2 - Resources
    check_gpu_availability || warnings=$((warnings + 1))
    check_disk_space || warnings=$((warnings + 1))

    # Tier 1 - Conflicts (auto-fix)
    check_container_conflicts || errors=$((errors + 1))
    check_port_conflicts || errors=$((errors + 1))

    # Tier 3 - Nice to have
    check_volume_paths || warnings=$((warnings + 1))
    check_network_conflicts || warnings=$((warnings + 1))
    check_images_available || true  # Info only

    printf "\n"

    if [ "$errors" -gt 0 ]; then
        printf "  ${RED}✗${RST} Pre-flight checks failed\n"
        return 2
    elif [ "$warnings" -gt 0 ] && [ "$STRICT" = "1" ]; then
        printf "  ${YEL}!${RST} Pre-flight checks completed with warnings (PREFLIGHT_STRICT=1)\n"
        return 1
    else
        printf "  ${GRN}✓${RST} All checks passed\n\n"
        return 0
    fi
}

# Run only when executed, so the tests can source the checks one at a time.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
