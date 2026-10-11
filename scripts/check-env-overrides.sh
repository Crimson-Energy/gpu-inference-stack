#!/usr/bin/env bash
# Detects when .env contains variables that override profile settings.
#
# PROVIDER SETTINGS belong in profiles (servers/server-*.env), not in .env.
# When .env has them, it defeats profile selection — the value you see in the
# profile is not what the container gets.
#
# .env should contain only:
#   - SERVER_PROFILE (which profile to load)
#   - Secrets (LITELLM_MASTER_KEY, etc.)
#   - Host-specific paths (DATA_DIR, HF_HOME, etc.)
#   - Fleet topology (GPU_*_URL, GPU_*_KEY for peer boxes)
#
# Exit codes:
#   0 = .env is clean or has only acceptable overrides
#   1 = .env has problematic overrides that shadow the profile

set -euo pipefail

BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
YEL=$(tput setaf 3 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)

# Provider settings that must NOT appear in .env (they belong in profiles)
PROVIDER_VARS=(
  # vLLM model/engine settings
  VLLM_MODEL
  VLLM_MODEL_NAME
  VLLM_MAX_MODEL_LEN
  VLLM_MAX_NUM_SEQS
  VLLM_GPU_MEMORY_UTILIZATION
  VLLM_TENSOR_PARALLEL_SIZE
  VLLM_KV_CACHE_DTYPE
  VLLM_TOOL_CALL_PARSER
  VLLM_REASONING_PARSER
  VLLM_EXPERT_PARALLEL
  VLLM_PREFIX_CACHING
  VLLM_CHUNKED_PREFILL
  VLLM_STRUCTURED_OUTPUTS_CONFIG
  VLLM_IMAGE

  # vLLM2/3 variants
  VLLM2_MODEL
  VLLM2_MODEL_NAME
  VLLM2_MAX_MODEL_LEN
  VLLM2_GPU_MEMORY_UTILIZATION
  VLLM3_MODEL
  VLLM3_MODEL_NAME
  VLLM3_MAX_MODEL_LEN
  VLLM3_GPU_MEMORY_UTILIZATION

  # llama.cpp model settings
  LLAMACPP_MODEL_FILE
  LLAMACPP_MODEL_NAME
  LLAMACPP_CTX_SIZE
  LLAMACPP_PARALLEL
  LLAMACPP_IMAGE

  # Ollama model settings
  OLLAMA_VISION_MODEL

  # Infinity model settings
  INFINITY_CMD
  INFINITY_IMAGE

  # Service enablement (hardware-specific)
  ENABLE_VLLM
  ENABLE_VLLM2
  ENABLE_VLLM3
  ENABLE_LLAMACPP
  ENABLE_OLLAMA
  ENABLE_INFINITY
  ENABLE_EMBEDDINGS
  ENABLE_STT
  STT_DEVICE
  STT_COMPUTE_TYPE
  STT_MODEL

  # Contract role mapping (topology-specific)
  CONTRACT_INTERACTIVE_MODEL
  CONTRACT_INTERACTIVE_API_BASE
  CONTRACT_BULK_MODEL
  CONTRACT_BULK_API_BASE
  CONTRACT_FAST_MODEL
  CONTRACT_FAST_API_BASE
  CONTRACT_VISION_MODEL
  CONTRACT_VISION_API_BASE
  CONTRACT_VISION_ALIAS
  CONTRACT_EMBED_ALIAS
  CONTRACT_RERANK_ALIAS
  CONTRACT_STT_ALIAS
  CONTRACT_STT_MODEL
  CONTRACT_STT_API_BASE
)

if [ ! -f /tmp/test.env ]; then
  exit 0  # No .env = no overrides
fi

found=()
while IFS= read -r line; do
  # Skip comments and empty lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue

  # Extract variable name (everything before =)
  var="${line%%=*}"
  var="${var#"${var%%[![:space:]]*}"}"  # trim leading space

  # Check if it's a provider variable
  for pvar in "${PROVIDER_VARS[@]}"; do
    if [ "$var" = "$pvar" ]; then
      # Get the value for reporting
      val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"  # trim leading space
      found+=("$var=$val")
      break
    fi
  done
done < .env

if [ "${#found[@]}" -eq 0 ]; then
  exit 0  # Clean
fi

# Report the overrides
printf "${YEL}⚠  .env contains provider settings that override the profile:${RST}\n\n"
for override in "${found[@]}"; do
  printf "  ${BOLD}%s${RST}\n" "$override"
done

printf "\n${DIM}These belong in ${BOLD}servers/server-*.env${RST}${DIM}, not in .env.${RST}\n"
printf "${DIM}When present in .env, they defeat profile selection — the value\n"
printf "in the profile is ignored and the container gets the .env value.${RST}\n\n"

printf "Fix by commenting them out in .env:\n"
for override in "${found[@]}"; do
  var="${override%%=*}"
  printf "  sed -i 's/^${var}=/# &/' .env\n"
done

printf "\nor remove them entirely:\n"
for override in "${found[@]}"; do
  var="${override%%=*}"
  printf "  sed -i '/^${var}=/d' .env\n"
done

printf "\n"
exit 1
