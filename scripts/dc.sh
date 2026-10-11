#!/usr/bin/env bash
# `docker compose` with this box's server profile layered in.
#
# A bare `docker compose` reads .env only, so every value that lives in the
# profile silently falls back to its compose default — which was written for a
# different class of card. Use this instead for anything ad-hoc:
#
#     scripts/dc.sh ps
#     scripts/dc.sh logs -f litellm
#     scripts/dc.sh config | less
#     scripts/dc.sh exec litellm sh
#
# Service-selecting commands need the compose profiles too; pass them yourself
# when targeting a profiled service, e.g.
#     scripts/dc.sh --profile vllm up -d vllm
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-profile.sh
. "$SCRIPT_DIR/lib-profile.sh"

if ! profile_assert_resolvable >/dev/null; then
    profile_assert_resolvable   # re-run for the message on stderr
    exit 1
fi

# Load SOPS-encrypted secrets (UI_USERNAME, UI_PASSWORD, API keys) into the
# environment. The secrets are decrypted in-memory and never written to disk.
# If .env.secrets or .age-key.txt is missing, this is a no-op — secrets are
# optional for basic operation.
if [ -f "$PROJECT_ROOT/.env.secrets" ] && [ -f "$PROJECT_ROOT/.age-key.txt" ]; then
    if command -v sops >/dev/null 2>&1; then
        export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/.age-key.txt"
        while IFS='=' read -r key val; do
            [ -n "$key" ] || continue
            # Only export if not already set (caller's env wins)
            [ -z "${!key+x}" ] && export "$key=$val"
        done < <(sops -d "$PROJECT_ROOT/.env.secrets" 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)
    fi
fi

# The optional stt role publishes its contract alias only on a box that enables
# it (lib-profile.sh stt_contract_alias). A caller's own value wins.
if [ -z "${CONTRACT_STT_ALIAS:-}" ]; then
    # shellcheck disable=SC2046
    _stt_alias="$(stt_contract_alias $(profile_env_file_args | sed 's/--env-file//g'))"
    [ -n "$_stt_alias" ] && export CONTRACT_STT_ALIAS="$_stt_alias"
fi

# Unquoted on purpose: profile_env_file_args emits separate --env-file words.
# shellcheck disable=SC2046
exec docker compose $(profile_env_file_args) -f "$PROJECT_ROOT/docker-compose.yml" "$@"
