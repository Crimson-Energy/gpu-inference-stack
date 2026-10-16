#!/usr/bin/env bash
# Tests that scripts/preflight-checks.sh never stops or removes a container
# that belongs to another stack, and that redis stays off the RESP port.
#
# WHY THIS EXISTS. On 2026-09-24 `make start` on ddai4 found host port 6379 in
# use, asked `docker ps --filter publish=6379` who held it, got
# `platform-falkordb` — deepdarshak's knowledge graph — called it "old
# container" and `docker stop`ped it. Our redis took 6379 seven seconds later
# and the graph could not come back. A port clash that should have been a loud
# refusal became a silent outage of another product.
#
# Spec: project-deepdarshak/.claude/specs/2026-09-24-gpu-stack-port-coexistence.md
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/scripts/preflight-checks.sh"

pass=0; fail=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
# The compose project is basename(pwd), so the fixture dir carries the name.
STACK="$FIX/gpu-inference-stack"
mkdir -p "$STACK/scripts"
cat > "$STACK/profile.env" <<'ENV'
LITELLM_PORT=18090
REDIS_PORT=6390
PROMETHEUS_PORT=19490
GRAFANA_PORT=13400
ENABLE_VLLM=false
ENV
printf '#!/bin/sh\necho "%s/profile.env"\n' "$STACK" > "$STACK/scripts/profile-files.sh"
chmod +x "$STACK/scripts/profile-files.sh"

# run_check <function> <listening port> <docker ps output>
# Prints the check's exit status, then every mutating docker call it made.
run_check() {
    local fn="$1" listen_port="$2" ps_out="$3"
    (
        cd "$STACK" || exit 99
        # shellcheck source=../preflight-checks.sh
        . "$PREFLIGHT"
        set +e
        ss()     { printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:* users:(("docker-proxy"))\n' "$listen_port"; }
        lsof()   { :; }
        sudo()   { :; }
        docker() {
            case "$1" in
                ps)          printf '%b' "$ps_out" ;;
                inspect)     printf '%s\n' "${STUB_SERVICE:-}" ;;
                stop|rm)     echo "MUTATED: docker $*" >> "$STACK/mutations" ;;
            esac
        }
        : > "$STACK/mutations"
        "$fn" > "$STACK/out" 2>&1
        echo "status=$?"
        cat "$STACK/mutations"
    )
}

echo ""
echo "preflight — port conflicts"
echo ""

# ── 1. A foreign holder is refused, never stopped ───────────────────────────
out="$(run_check check_port_conflicts 6390 \
  'platform-falkordb\tddplatform\t127.0.0.1:6390->6379/tcp\n')"
is "a port held by another project's container is a refusal (exit 2)" \
   "status=2" "$(printf '%s\n' "$out" | head -1)"
is "…and that container is NOT stopped" \
   "" "$(printf '%s\n' "$out" | grep MUTATED || true)"
grep -q 'platform-falkordb' "$STACK/out" \
  && ok "…and the refusal names the holder" \
  || bad "…and the refusal names the holder" "platform-falkordb in output" "$(cat "$STACK/out")"
grep -q 'ddplatform' "$STACK/out" \
  && ok "…and names the project that owns it" \
  || bad "…and names the project that owns it" "ddplatform in output" "$(cat "$STACK/out")"
grep -q 'REDIS_PORT' "$STACK/out" \
  && ok "…and names the variable that moves our port" \
  || bad "…and names the variable that moves our port" "REDIS_PORT in output" "$(cat "$STACK/out")"

# ── 2. A container with no compose project is foreign too ───────────────────
out="$(run_check check_port_conflicts 6390 \
  'some-redis\t\t0.0.0.0:6390->6379/tcp\n')"
is "a holder with no compose label is not stopped" \
   "" "$(printf '%s\n' "$out" | grep MUTATED || true)"

# ── 3. Our own leftover is still auto-fixed ─────────────────────────────────
out="$(run_check check_port_conflicts 6390 \
  'redis\tgpu-inference-stack\t127.0.0.1:6390->6379/tcp\n')"
is "a holder from this compose project is stopped" \
   "MUTATED: docker stop redis" "$(printf '%s\n' "$out" | grep MUTATED || true)"
is "…and the check passes" "status=0" "$(printf '%s\n' "$out" | head -1)"

# ── 3b. A container the profile runs is not a leftover ─────────────────────
# `make start` on a running stack stopped its own healthy containers — vLLM
# included, a cold reload of tens of GB on every `<host>-up` (ddai4,
# 2026-10-16). `compose up -d` reconciles a service the profile runs; only a
# container of a service it does not run is a leftover.
out="$(STUB_SERVICE=redis PREFLIGHT_SERVICES="redis litellm vllm" run_check check_port_conflicts 6390 \
  'redis\tgpu-inference-stack\t127.0.0.1:6390->6379/tcp\n')"
is "a running container of a profile service is not stopped" \
   "" "$(printf '%s\n' "$out" | grep MUTATED || true)"
is "…and is not a conflict" "status=0" "$(printf '%s\n' "$out" | head -1)"
out="$(STUB_SERVICE=redis-old PREFLIGHT_SERVICES="redis litellm vllm" run_check check_port_conflicts 6390 \
  'redis-old\tgpu-inference-stack\t127.0.0.1:6390->6379/tcp\n')"
is "a container of a service the profile does not run is still stopped" \
   "MUTATED: docker stop redis-old" "$(printf '%s\n' "$out" | grep MUTATED || true)"

# ── 4. Matching is on the HOST port, not the container port ─────────────────
# platform-falkordb publishes 6379 INSIDE on a different host port; it does not
# hold host 6390 and must not be picked as the culprit.
out="$(run_check check_port_conflicts 6390 \
  'platform-falkordb\tddplatform\t127.0.0.1:6379->6379/tcp\nredis\tgpu-inference-stack\t127.0.0.1:6390->6379/tcp\n')"
is "the holder is found by host port, so only our redis is stopped" \
   "MUTATED: docker stop redis" "$(printf '%s\n' "$out" | grep MUTATED || true)"

echo ""
echo "preflight — container name conflicts"
echo ""

# ── 5. A foreign same-named container is not removed ────────────────────────
out="$(run_check check_container_conflicts 0 \
  "grafana\tabc123456789\tsomeproject\t/home/x/other-stack\t2026-09-01 10:00:00 +0000\n")"
is "a same-named container from another stack is NOT removed" \
   "" "$(printf '%s\n' "$out" | grep MUTATED || true)"
is "…and is a refusal (exit 2)" "status=2" "$(printf '%s\n' "$out" | head -1)"

# ── 6. A leftover of this checkout under an old project name is removed ─────
out="$(run_check check_container_conflicts 0 \
  "grafana\tabc123456789\toldname\t$STACK\t2026-09-01 10:00:00 +0000\n")"
is "a same-named container from THIS repo's working dir is removed" \
   "MUTATED: docker rm -f grafana" "$(printf '%s\n' "$out" | grep MUTATED || true)"

echo ""
echo "redis — off the RESP port, loopback, one default"
echo ""

# ── 7. compose default ───────────────────────────────────────────────────────
COMPOSE="$REPO_ROOT/docker-compose.yml"
grep -qF '"${REDIS_BIND_ADDR:-127.0.0.1}:${REDIS_PORT:-6390}:6379"' "$COMPOSE" \
  && ok "compose publishes redis on 127.0.0.1:6390 by default" \
  || bad "compose publishes redis on 127.0.0.1:6390 by default" \
         '"${REDIS_BIND_ADDR:-127.0.0.1}:${REDIS_PORT:-6390}:6379"' \
         "$(grep -n 'REDIS_PORT' "$COMPOSE")"

# ── 8. preflight default agrees with compose ────────────────────────────────
grep -qF 'REDIS_PORT:-6390' "$PREFLIGHT" \
  && ok "preflight checks the same default redis port" \
  || bad "preflight checks the same default redis port" "REDIS_PORT:-6390" \
         "$(grep -n 'REDIS_PORT' "$PREFLIGHT")"

# ── 9. no profile pins a per-host redis port ────────────────────────────────
pins="$(grep -lE '^REDIS_PORT=' "$REPO_ROOT"/servers/*.env 2>/dev/null || true)"
is "no server profile pins REDIS_PORT (every box inherits the one default)" \
   "" "$pins"

echo ""
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
