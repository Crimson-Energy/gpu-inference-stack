#!/usr/bin/env bash
# The optional gpu/stt/whisper contract role.
#
# WHY THIS EXISTS. Speech-to-text is served for consumers' voice input (the
# Maritime Advisor's microphone, first). It is OPTIONAL and OFF by default, so
# the alias must be unpublished unless the box runs the backend: LiteLLM
# publishes every alias in config.yaml whether or not it answers, and a
# published-but-dead role is worse than an absent one (README, contract).
# So the alias defaults to unserved/stt, and deploy.sh names it gpu/stt/whisper
# only when ENABLE_STT=true.
# Spec: project-deepdarshak/.claude/specs/2026-10-11-voice-questions-for-the-advisor.md (REQ-STT-01)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE="$REPO_ROOT/docker-compose.yml"
CONFIG="$REPO_ROOT/config/litellm/config.yaml"
DEPLOY="$REPO_ROOT/scripts/deploy.sh"

pass=0; fail=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "gpu/stt/whisper role"

# ── compose: the stt service ───────────────────────────────────────────────
svc="$(python3 - "$COMPOSE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
s = doc["services"].get("stt") or {}
env = s.get("environment") or []
env = env if isinstance(env, list) else [f"{k}={v}" for k, v in env.items()]
print("profiles=" + ",".join(s.get("profiles") or []))
print("ttl=" + next((e.split("=", 1)[1] for e in env if e.startswith("WHISPER__TTL=")), ""))
print("entry=" + " ".join(s.get("entrypoint") or []))
print("model=" + next((e.split("=", 1)[1] for e in env if e.startswith("STT_MODEL=")), ""))
print("probe=" + ("--kind transcription" in " ".join(s.get("healthcheck", {}).get("test", []))) * "yes")
lit = doc["services"]["litellm"].get("environment") or []
print("alias=" + next((e.split("=", 1)[1] for e in lit if e.startswith("CONTRACT_STT_ALIAS=")), ""))
print("base=" + next((e.split("=", 1)[1] for e in lit if e.startswith("CONTRACT_STT_API_BASE=")), ""))
PY
)"
val() { printf '%s\n' "$svc" | sed -n "s/^$1=//p"; }

is "stt service is behind profile 'stt'"                 "stt" "$(val profiles)"
is "the model is never unloaded (a reload costs 13 s)"   "-1"  "$(val ttl)"
is "entrypoint installs + warms the model (0.8.3 has no preload)" "/stt-entrypoint.sh" "$(val entry)"
is "the model is configurable, turbo by default"         '${STT_MODEL:-deepdml/faster-whisper-large-v3-turbo-ct2}' "$(val model)"
is "healthcheck probes a real transcription"             "yes" "$(val probe)"
is "litellm alias defaults to unserved/stt"              '${CONTRACT_STT_ALIAS:-unserved/stt}' "$(val alias)"
is "litellm api_base defaults to the stt service"        '${CONTRACT_STT_API_BASE:-http://stt:8000/v1}' "$(val base)"

# ── litellm config entry ──────────────────────────────────────────────────
entry="$(python3 - "$CONFIG" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for m in doc["model_list"]:
    if m["model_name"] == "os.environ/CONTRACT_STT_ALIAS":
        print(m.get("model_info", {}).get("mode", ""), m["litellm_params"].get("api_base", ""))
        break
PY
)"
is "config.yaml publishes CONTRACT_STT_ALIAS as audio_transcription" \
   "audio_transcription os.environ/CONTRACT_STT_API_BASE" "$entry"

# ── deploy.sh: ENABLE_STT gates the profile AND the published name ─────────
# Run only the profile/alias block, extracted between its markers, so the test
# needs no docker.
block="$(sed -n '/^# >>> stt role/,/^# <<< stt role/p' "$DEPLOY")"
run_block() { env -i PATH="$PATH" "$@" bash -c "PROFILES=litellm; $block"'
printf "%s|%s\n" "$PROFILES" "${CONTRACT_STT_ALIAS:-}"' 2>/dev/null | tail -1; }

is "ENABLE_STT unset: no profile, alias untouched" "litellm|"                    "$(run_block)"
is "ENABLE_STT=true: profile + contract name"      "litellm,stt|gpu/stt/whisper" "$(run_block ENABLE_STT=true)"
is "an explicit alias wins over the default"        "litellm,stt|unserved/stt"   "$(run_block ENABLE_STT=true CONTRACT_STT_ALIAS=unserved/stt)"

# ── make start / dc.sh: the same rule, read from the profile files ─────────
# `make start` never runs deploy.sh: it calls dc.sh, which passes the profile
# as --env-file. stt_contract_alias reads ENABLE_STT / CONTRACT_STT_ALIAS from
# those files last-wins (without sourcing them) and prints the alias to export.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'ENABLE_STT=true\n'                                > "$tmp/on.env"
printf 'ENABLE_STT=false\n'                               > "$tmp/off.env"
printf 'CONTRACT_STT_ALIAS=unserved/stt\n'                > "$tmp/pinned.env"
alias_for() { (. "$REPO_ROOT/scripts/lib-profile.sh"; stt_contract_alias "$@"); }
is "profile enables stt: gpu/stt/whisper"         "gpu/stt/whisper" "$(alias_for "$tmp/on.env")"
is "a later file disables it: nothing"            ""                "$(alias_for "$tmp/on.env" "$tmp/off.env")"
is "no ENABLE_STT anywhere: nothing"              ""                "$(alias_for "$tmp/pinned.env")"
is "a file pins the alias: that file wins"        ""                "$(alias_for "$tmp/on.env" "$tmp/pinned.env")"
grep -q 'stt_contract_alias' "$REPO_ROOT/scripts/dc.sh" \
    && ok "dc.sh applies it" || bad "dc.sh applies it" "calls stt_contract_alias" "does not"
grep -q 'ENABLE_STT:-false}" *= "true" \] && p="\$\$p --profile stt"' "$REPO_ROOT/Makefile" \
    && ok "Makefile enabled_profiles adds --profile stt" \
    || bad "Makefile enabled_profiles adds --profile stt" "a line for ENABLE_STT" "none"

# ── a consumer key can be granted it ──────────────────────────────────────
# Consumer keys carry an allow-list; ember-deepdrishti's had the six other roles
# and 403'd gpu/stt/whisper until it was added (2026-10-11).
grep -q 'all)  models=.*"gpu/stt/whisper"' "$REPO_ROOT/Makefile" \
    && ok "create-key: 'all' includes gpu/stt/whisper" \
    || bad "create-key: 'all' includes gpu/stt/whisper" "listed" "missing"
grep -qE '7\) models="\$\$models\\"gpu/stt/whisper' "$REPO_ROOT/Makefile" \
    && ok "create-key: choice 7 is gpu/stt/whisper" \
    || bad "create-key: choice 7 is gpu/stt/whisper" "a 7) case" "none"

# ── documented ────────────────────────────────────────────────────────────
grep -q '^| `gpu/stt/whisper` |.*| optional |$' "$REPO_ROOT/README.md" \
    && ok "README contract table has the optional row" \
    || bad "README contract table has the optional row" "a gpu/stt/whisper row" "none"
for v in ENABLE_STT STT_DEVICE CONTRACT_STT_ALIAS CONTRACT_STT_API_BASE; do
    grep -q "^  $v$" "$REPO_ROOT/scripts/check-env-overrides.sh" \
        && ok "check-env-overrides knows $v" \
        || bad "check-env-overrides knows $v" "listed" "missing"
    grep -qE "^#? *$v=" "$REPO_ROOT/.env.example" \
        && ok ".env.example documents $v" \
        || bad ".env.example documents $v" "documented" "missing"
done

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
