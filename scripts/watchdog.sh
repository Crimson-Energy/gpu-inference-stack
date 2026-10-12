#!/usr/bin/env bash
# Restart stack containers that Docker reports unhealthy.
#
# THE HALF THAT ACTS. `scripts/healthprobe.py` detects a wedged engine from
# inside the container; nothing inside a container can restart it. Docker's
# `restart: unless-stopped` fires on process EXIT and never on health status,
# so an unhealthy container is labelled and then left running indefinitely —
# on 2026-09-12 an Infinity container served no embeddings for 11 minutes and
# would have continued until someone noticed by hand.
#
# Runs on the HOST rather than as an autoheal sidecar because the sidecar
# pattern needs /var/run/docker.sock mounted into a container, and a mounted
# socket is root-equivalent on a box that also runs the platform stack. Here
# the privilege is the operator's own, already-present docker access.
#
# Reluctant by design. An engine under load is slow, not hung, so a container
# must be unhealthy across CONSECUTIVE polls before it is touched, and each
# restart is rate-limited: restarting a busy vLLM costs minutes of model load,
# and a watchdog that flaps is worse than the fault it chases.
#
#   watchdog.sh                  one pass, restart what qualifies
#   watchdog.sh --dry-run        report only
#   watchdog.sh --once           alias for one pass (systemd timer default)
#
# Install as a timer:  see docs/TROUBLESHOOTING.md
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${WATCHDOG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gpu-inference-stack}"
#: Consecutive unhealthy observations before restarting. With a 60s timer that
#: is ~3 minutes of confirmed failure, on top of the 5 failed probes Docker
#: already needs to call a container unhealthy at all.
THRESHOLD="${WATCHDOG_THRESHOLD:-3}"
#: Never restart the same container more often than this, whatever the state
#: says. A container that is unhealthy again 60s after a restart is not being
#: fixed by restarting, and hammering it hides that.
COOLDOWN_S="${WATCHDOG_COOLDOWN_S:-900}"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --once) ;;                      # one pass is the only mode
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "watchdog: unknown argument $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" 2>/dev/null

log() { printf '%s watchdog: %s\n' "$(date -Is)" "$*"; }

# Only this project's containers: the host runs other stacks, and restarting
# somebody else's unhealthy container is not this script's business.
# One writer, including timer/manual overlap. A failed inventory is not health.
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0
if ! inventory=$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-gpu-inference-stack}" \
    --filter "health=unhealthy" --format '{{.ID}} {{.Names}}' 2>/dev/null); then
    log "Docker inventory failed — preserving state, no restarts"
    exit 1
fi

declare -A unhealthy=()
while read -r id name; do
    [ -n "$id" ] || continue
    unhealthy["$id"]="$name"
done <<< "$inventory"

# A recovered/replaced container loses its streak even if others remain sick.
if [ "$DRY_RUN" -eq 0 ]; then
    for file in "$STATE_DIR"/streak.*; do
        [ -f "$file" ] || continue
        id="${file##*/streak.}"
        [ -n "${unhealthy[$id]+present}" ] || rm -f -- "$file"
    done
fi

for id in "${!unhealthy[@]}"; do
    name="${unhealthy[$id]}"
    streak_file="$STATE_DIR/streak.$id"
    last_file="$STATE_DIR/last_restart.$id"

    streak=$(cat "$streak_file" 2>/dev/null || echo 0)
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
    streak=$((streak + 1))
    [ "$DRY_RUN" -eq 1 ] || echo "$streak" > "$streak_file"

    if [ "$streak" -lt "$THRESHOLD" ]; then
        log "$name unhealthy ($streak/$THRESHOLD) — waiting"
        continue
    fi

    now=$(date +%s)
    last=$(cat "$last_file" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $((now - last)) -lt "$COOLDOWN_S" ]; then
        log "$name unhealthy but restarted $((now - last))s ago (cooldown ${COOLDOWN_S}s) — NOT restarting; this needs a human"
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$name unhealthy ($streak) — would restart (dry run)"
        continue
    fi

    log "$name unhealthy for $streak consecutive checks — restarting"
    if docker restart "$id" >/dev/null 2>&1; then
        echo "$now" > "$last_file"
        rm -f "$streak_file"
        log "$name restarted"
    else
        log "$name RESTART FAILED — leaving it alone"
    fi
done

# ── A vLLM that cannot START (spec project-deepdarshak/.claude/specs/completed/
#    2026-10-10-gpu-watchdog-recovers-a-starved-vllm.md, extended by
#    2026-10-12-gpu-watchdog-releases-every-gpu-tenant.md) ────────────────────
#
# Not the unhealthy path above: vLLM refuses to start when the card has less
# free memory than its gpu-memory-utilization asks for, exits, and Docker's
# restart policy relaunches it into the same refusal — a crash loop that is
# never "unhealthy", so nothing above sees it. On a Blackwell-32GB box the
# memory is held by the co-resident GPU tenants: Infinity (3.8 GB at its
# floor, more once its cache grows) and, since 2026-10-11, stt (1.3 GB). All
# of them fit beside a RUNNING vLLM; none of them fit beside a STARTING one.
# So the tenants are STOPPED — a restarted one reloads its models before
# vLLM's next start and starves it again — and started once vLLM is healthy,
# or after WATCHDOG_RELEASE_MAX_S whatever, so the watchdog never leaves
# embeddings or speech down by itself. vLLM itself is not touched.
STARVED_PATTERN='on startup is less than desired GPU memory utilization'
GPU_TENANTS="${WATCHDOG_GPU_TENANTS:-infinity stt}"
RELEASE_MAX_S="${WATCHDOG_RELEASE_MAX_S:-900}"

if ! listing=$(docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-gpu-inference-stack}" \
    --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.service"}} {{.Status}}' 2>/dev/null); then
    log "Docker listing failed — no starved-engine check this pass"
    exit 0
fi

tenant_ids=(); tenant_names=()
while read -r id name service status; do
    [ -n "$id" ] || continue
    # Only running ones: a tenant the operator stopped stays stopped.
    case "$status" in Up*) ;; *) continue ;; esac
    for t in $GPU_TENANTS; do
        if [ "$service" = "$t" ]; then tenant_ids+=("$id"); tenant_names+=("$name"); fi
    done
done <<< "$listing"

# Return what an earlier pass released, once its engine is up (or too late).
while read -r id name service status; do
    [ -n "$id" ] || continue
    [[ "$service" =~ ^vllm[0-9]*$ ]] || continue
    released_file="$STATE_DIR/released.$name"
    [ -f "$released_file" ] || continue
    read -r since ids < "$released_file"
    [[ "${since:-}" =~ ^[0-9]+$ ]] || since=0
    now=$(date +%s)
    case "$status" in
        *"(healthy)"*) log "$name is healthy — starting the GPU tenants it was given room by" ;;
        *) [ $((now - since)) -ge "$RELEASE_MAX_S" ] || continue
           log "$name still not healthy $((now - since))s after its GPU tenants were stopped — starting them anyway; this needs a human" ;;
    esac
    [ "$DRY_RUN" -eq 1 ] && continue
    for tid in $ids; do
        docker start "$tid" >/dev/null 2>&1 || log "start of $tid FAILED — this needs a human"
    done
    rm -f "$released_file"
done <<< "$listing"

while read -r id name service status; do
    [ -n "$id" ] || continue
    [[ "$service" =~ ^vllm[0-9]*$ ]] || continue
    case "$status" in *"(healthy)"*) continue ;; esac
    [ -f "$STATE_DIR/released.$name" ] && continue
    # Read once, then match: `docker logs | grep -q` under pipefail returns 141
    # (SIGPIPE) on any log bigger than a pipe buffer, and read as "no match".
    engine_log=$(docker logs --since 10m --tail 400 "$id" 2>&1)
    grep -qF "$STARVED_PATTERN" <<< "$engine_log" || continue

    if [ "${#tenant_ids[@]}" -eq 0 ]; then
        log "$name cannot start: GPU memory below its utilization, and no GPU tenant ($GPU_TENANTS) in this project to release it — this needs a human"
        continue
    fi
    pair_file="$STATE_DIR/last_starved_restart.$name"
    now=$(date +%s)
    last=$(cat "$pair_file" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $((now - last)) -lt "$COOLDOWN_S" ]; then
        log "$name still cannot start $((now - last))s after its GPU tenants were released (cooldown ${COOLDOWN_S}s) — this needs a human"
        continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$name cannot start (GPU memory held by ${tenant_names[*]}) — would stop ${tenant_names[*]} until it is healthy (dry run)"
        continue
    fi
    log "$name cannot start: GPU memory held by ${tenant_names[*]} — stopping them until it is healthy"
    stopped=()
    for i in "${!tenant_ids[@]}"; do
        if docker stop "${tenant_ids[$i]}" >/dev/null 2>&1; then
            stopped+=("${tenant_ids[$i]}")
        else
            log "${tenant_names[$i]} STOP FAILED — this needs a human"
        fi
    done
    echo "$now" > "$pair_file"
    echo "$now ${stopped[*]}" > "$STATE_DIR/released.$name"
done <<< "$listing"
