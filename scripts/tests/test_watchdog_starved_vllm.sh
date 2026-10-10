#!/usr/bin/env bash
# Tests that scripts/watchdog.sh recovers a vLLM that cannot start because a
# co-resident Infinity holds the GPU memory it needs.
#
# WHY THIS EXISTS. On 2026-10-10 (ddai3) the watchdog restarted an unhealthy
# vLLM; it then exited at every start ("Free memory on device (25.58/31.37 GiB)
# on startup is less than desired GPU memory utilization (0.84, 26.35 GiB)")
# because Infinity's PyTorch cache had grown to 5.65 GiB. Docker relaunched it
# 38 times in 32 minutes and the watchdog, which only acts on UNHEALTHY
# containers, did nothing: every LLM call on the box failed until Infinity was
# restarted by hand.
#
# Spec: project-deepdarshak/.claude/specs/2026-10-10-gpu-watchdog-recovers-a-starved-vllm.md
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$(cd "$SCRIPT_DIR/.." && pwd)/watchdog.sh"

pass=0; fail=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
REFUSAL='ValueError: Free memory on device cuda:0 (25.58/31.37 GiB) on startup is less than desired GPU memory utilization (0.84, 26.35 GiB).'

# A stub `docker` on PATH, driven by files in $FIX/world:
#   unhealthy      lines "<id> <name>" for `docker ps --filter health=unhealthy`
#   containers     lines "<id> <name> <compose service> <docker status>" for the
#                  project listing (`docker ps -a`), status as Docker prints it
#   logs.<id>      what `docker logs` prints for that container
# Every restart is appended to $FIX/restarts.
mkdir -p "$FIX/bin" "$FIX/world"
cat > "$FIX/bin/docker" <<'STUB'
#!/usr/bin/env bash
W="$WD_WORLD"
case "$1" in
    ps)
        args="$*"
        case "$args" in
            *health=unhealthy*) cat "$W/unhealthy" 2>/dev/null || true ;;
            *)                  cat "$W/containers" 2>/dev/null || true ;;
        esac ;;
    logs)    id="${@: -1}"; cat "$W/logs.$id" 2>/dev/null || true ;;
    restart) echo "restart $2" >> "$WD_RESTARTS" ;;
    *)       : ;;
esac
STUB
chmod +x "$FIX/bin/docker"

reset_world() { rm -rf "$FIX/world" "$FIX/state" "$FIX/restarts"; mkdir -p "$FIX/world" "$FIX/state"; : > "$FIX/restarts"; }
run_wd() {
    PATH="$FIX/bin:$PATH" WD_WORLD="$FIX/world" WD_RESTARTS="$FIX/restarts" \
        WATCHDOG_STATE_DIR="$FIX/state" bash "$WATCHDOG" "$@" 2>&1
}
restarts() { tr '\n' ' ' < "$FIX/restarts" | sed 's/ $//'; }

echo "watchdog: a starved vLLM"

reset_world
printf 'v1 vllm-new vllm Restarting (1) 4 seconds ago\ni1 infinity infinity Up 10 hours (healthy)\n' > "$FIX/world/containers"
echo "$REFUSAL" > "$FIX/world/logs.v1"
out=$(run_wd)
is  "a starved vLLM gets Infinity restarted, and vLLM is left to its restart policy" "restart i1" "$(restarts)"
has "it says why" "held by" "$out"

: > "$FIX/restarts"
out=$(run_wd)
is  "still starved inside the cooldown: nothing is restarted again" "" "$(restarts)"
has "and a human is asked for" "needs a human" "$out"

reset_world
printf 'v1 vllm-new vllm Up 2 hours (unhealthy)\ni1 infinity infinity Up 10 hours (healthy)\n' > "$FIX/world/containers"
echo "INFO some other failure" > "$FIX/world/logs.v1"
run_wd >/dev/null
is  "an unhealthy vLLM for another reason does not touch Infinity" "" "$(restarts)"

reset_world
printf 'v1 vllm-new vllm Up 5 minutes (healthy)\ni1 infinity infinity Up 10 hours (healthy)\n' > "$FIX/world/containers"
echo "$REFUSAL" > "$FIX/world/logs.v1"
run_wd >/dev/null
is  "a healthy vLLM is never acted on, whatever its old log says" "" "$(restarts)"

reset_world
echo "v1 vllm-new vllm Up 20 seconds (health: starting)" > "$FIX/world/containers"
echo "$REFUSAL" > "$FIX/world/logs.v1"
out=$(run_wd)
is  "with no Infinity in the project nothing is restarted" "" "$(restarts)"
has "and a human is asked for" "needs a human" "$out"

reset_world
printf 'v2 vllm2 vllm2 Restarting (1) 2 seconds ago\ni1 infinity infinity Up 10 hours (healthy)\n' > "$FIX/world/containers"
echo "$REFUSAL" > "$FIX/world/logs.v2"
out=$(run_wd --dry-run)
is  "a dry run mutates nothing (and a second engine, vllm2, is covered too)" "" "$(restarts)"
has "and reports what it would do" "would restart" "$out"

echo "watchdog: the unhealthy path is unchanged"

reset_world
echo "c1 infinity" > "$FIX/world/unhealthy"
echo "c1 infinity infinity Up 10 hours (unhealthy)" > "$FIX/world/containers"
for _ in 1 2; do run_wd >/dev/null; done
is  "two unhealthy passes: not yet" "" "$(restarts)"
run_wd >/dev/null
is  "the third consecutive unhealthy pass restarts it" "restart c1" "$(restarts)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
