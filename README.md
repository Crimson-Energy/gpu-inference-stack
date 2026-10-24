# GPU Inference Stack

A production-ready, modular GPU inference platform for running multiple LLM servers with unified API access, monitoring, and management.

## Features

- **Multiple Inference Backends**: Ollama, vLLM, Text Embeddings
- **Unified API Gateway**: LiteLLM provides a single OpenAI-compatible API for all models
- **Monitoring & Observability**: Prometheus + Grafana with GPU metrics
- **Caching**: Redis-based response caching for improved performance
- **Modular Configuration**: Server profiles for different GPU configurations
- **Production Ready**: Health checks, logging, resource limits
- **Easy Deployment**: Docker Compose with automated scripts

## The consumer contract (`gpu/<task>/<role>`)

Consumers — ember-ai and any other client — address **only** these aliases.
Everything else in `config/litellm/config.yaml` is this box's internal topology
and may be renamed or re-pointed freely.

| alias | what publishing it promises | required |
|---|---|---|
| `gpu/chat/interactive` | tool-calling, ≥32k ctx, JSON `response_format`, latency-tuned | yes |
| `gpu/chat/bulk` | tool-calling, ≥32k ctx, JSON `response_format`, throughput-tuned | yes |
| `gpu/chat/fast` | tool-calling, ≥16k ctx, low latency | yes |
| `gpu/chat/vision` | image input | optional |
| `gpu/embed/bge-m3` | `BAAI/bge-m3` exactly, 1024-dim | yes |
| `gpu/rerank/bge-reranker-v2-m3` | `BAAI/bge-reranker-v2-m3` cross-encoder | optional |
| `gpu/stt/whisper` | `POST /v1/audio/transcriptions` (multipart `file`, optional `language`/`prompt`) → `{text}`, Whisper-family; published only when `ENABLE_STT=true` | optional |

The contract is a set of **roles**, and each box fills each role with whatever
weights it can run — a 96GB box serves Qwen3.6-35B behind
`gpu/chat/interactive`, a 32GB box serves Qwen3-30B-A3B. The consumer's config
does not change. That is the whole point: **consumers choose a capability tier,
deployments choose the weights.**

The two embed/rerank rows name a *model* rather than a role, deliberately. A
vector index is built with one specific embedder and cannot be re-pointed at a
different one without re-embedding the corpus — and a same-dimension substitute
does not error, it silently returns wrong neighbours. Those two are a **data**
contract; the chat rows are a **capability** contract.

`interactive` and `bulk` default to the same deployment. They are separate
names so a consumer can place them on different servers — interactive chat on a
big shared box, bulk extraction on a local one — without either side editing
YAML.

### Filling the roles

Each role binds to a model + backend through `CONTRACT_*` variables in `.env`
(see the `EMBER CONTRACT` section of `.env.example`). Defaults: chat roles →
the local vLLM, vision → local Ollama, embed/rerank → local Infinity.

Role-named variables are correct *here* and wrong on the consumer side. This is
the layer that decides "role X is served by model Y at backend Z", so the role
belongs in the name. A consumer's variables name **servers**
(`GPU_<SERVER>_URL`), never tasks — it is addressing infrastructure, not
choosing roles.

A role you cannot serve should be left **unserved** rather than pointed at
something that half-works. Consumers check `/v1/models` at boot: they route
around a missing optional role (vision falls back to a cloud provider) and
refuse to start on a missing required one.

### How consumers address this stack

A consumer points one variable per server at the **bare root** of this stack's
LiteLLM — `http://<this host>:8080` — with **no `/v1` and no path**, plus a
virtual key. For ember-ai that is `GPU_STACK_URL` / `GPU_STACK_KEY` in its
`.env.local`, then `make check-llm`.

The bare root matters, and is worth repeating to anyone integrating: it is what
lets a consumer use one variable and one LiteLLM provider prefix for all three
call types, because this proxy serves `/chat/completions`, `/embeddings` and
`/v1/rerank` (LiteLLM's rerank client appends that `/v1` itself). A base ending
in `/v1` still works for chat and embeddings — so the integration looks
healthy — and breaks only rerank, which degrades the consumer's retrieval to
un-reranked order rather than raising.

### Verifying

`./scripts/health-check.sh` probes the alias *names*, not just the backing
services — a backend can be healthy while the alias in front of it is
misconfigured (wrong served-model name, unresolved env var). Run it before
pointing a consumer at a new box.

### Load: how many requests to send

vLLM queues rather than rejects. A consumer that sends too much never gets an
error to back off from — every consumer's latency just climbs together. So the
stack publishes its load, per role, at the same root and with the same virtual
key as inference:

```bash
curl -H "Authorization: Bearer $KEY" http://<this host>:8080/capacity                       # every served role
curl -H "Authorization: Bearer $KEY" http://<this host>:8080/capacity/gpu/chat/bulk         # one role
curl -H "Authorization: Bearer $KEY" "http://<this host>:8080/capacity/gpu/chat/bulk?tokens=30000"
```

```json
{"roles": {"gpu/chat/bulk": {"backend": "vllm", "healthy": true, "state": "idle",
  "in_flight": 1, "waiting": 0, "max_concurrency": 64, "kv_cache_usage": 0.05,
  "free_slots": 63, "recommended_concurrency": 63,
  "rates": {"generation_tokens_per_s": 182.0, "mean_latency_s": 4.1, "mean_queue_s": 0.0}}},
 "gpus": [{"index": 0, "utilization": 0.98, "memory_free_mib": 660}]}
```

**Read `recommended_concurrency` as "how many more requests to put in flight
now"** and re-read it every few seconds (it is refreshed every
`CAPACITY_POLL_SECONDS`, default 5) — not once at startup, because other
consumers share the GPU. `state` is `idle` / `available` / `busy` /
`saturated` / `down`: `busy` offers half the free room, so two consumers
filling a box at once do not overshoot it together; `saturated` (a queue has
formed, or the KV cache is ≥95% full) offers 0 with a `retry_after_s`.
`?tokens=N` sizes the answer for requests of ~N tokens (prompt + output) by
free KV cache, which is what really bounds long-context work: 64 free slots
but room in the cache for 6 × 30k-token requests means 6.

The numbers come from each engine's own metrics — vLLM `/metrics`, Infinity
`/models`, llama.cpp `/slots`, Ollama `/api/ps`, DCGM for the GPU — read by the
`capacity` service (`scripts/capacity.py`, stdlib Python), which LiteLLM
proxies as an authenticated pass-through. A role served by a peer box is
answered by that peer's own `/capacity`. Prometheus scrapes the same data as
`gis_capacity_*{role,backend}`. The service learns which engine fills which
role from its copy of the `CONTRACT_*` block; `scripts/check-contract-wiring.sh`
(run by `deploy.sh`) refuses a deploy where it and litellm's disagree.

A key must list the route in its metadata —
`{"allowed_passthrough_routes": ["/capacity"]}` — or LiteLLM answers 403.
The `.env.example` recipes include it; for keys minted before,
`python3 scripts/grant-capacity-access.py` (add `--dry-run` first) adds it to
every key, keeping their other metadata.

### Keys

Do not give consumers `LITELLM_MASTER_KEY`; it is an admin credential. Mint a
virtual key per consuming app instead, so each gets its own spend tracking,
rate limit, and revocation — see `.env.example` for the `/key/generate` call.

### Retries and caching live in the consumer

This stack sets `num_retries: 0` and `cache: false`, deliberately. Retries must
live in exactly one tier: a consumer that retries twice against a stack that
retries twice turns one logical call into up to nine upstream hits. The
consumer's gateway is the right owner because it is the tier that can fail a
call over to a different provider entirely, which this stack cannot. Response
caching is off because a cache on *shared* inference serves one consumer's
answer to another, and makes bulk runs non-reproducible in a way that looks
like model nondeterminism.

## Architecture

```
┌─────────────────────────────────────────┐
│          LiteLLM Gateway                │
│    (Unified OpenAI-compatible API)      │
└──────────┬──────────────────────────────┘
           │
    ┌──────┴────────┬──────────────┬────────────┐
    │               │              │            │
┌───▼────┐   ┌─────▼─────┐  ┌────▼────┐  ┌────▼────┐
│ Ollama │   │   vLLM    │  │ Embeddings│ │  Redis  │
│ Models │   │  Models   │  │  Service  │ │  Cache  │
└────────┘   └───────────┘  └───────────┘ └─────────┘
     │              │              │
     └──────────────┴──────────────┘
                    │
            ┌───────▼────────┐
            │   GPU (NVIDIA) │
            └────────────────┘

              Monitoring Stack
    ┌──────────────┬─────────────────┐
    │  Prometheus  │     Grafana     │
    │   (Metrics)  │   (Dashboards)  │
    └──────────────┴─────────────────┘
```

### Choosing an inference runtime

Three backends can serve chat: **Ollama**, **vLLM**, and **llama.cpp**. vLLM is
the default and stays the right choice for most boxes.

Reach for **llama.cpp** when one of these holds:

- **The weights are GGUF and larger than VRAM.** Its `-ncmoe` / `-ot`
  CPU-offload path is mature — expert tensors go to host memory and the
  server keeps serving.
- **The box predates FP8/FP4 tensor cores.** On `sm_86` (Ampere, e.g. the
  A6000) the FP8 and NVFP4 quants modern vLLM recipes assume have no native
  kernel path.
- **The model is `qwen4exp` / Qwen3.8-Flash-Next.** vLLM's host-memory PLE
  prefetch for that architecture is still an open feature request upstream.

**vLLM and llama.cpp are mutually exclusive per GPU.** `scripts/deploy.sh`
exits non-zero if both are enabled — neither card in this fleet has the
headroom for two engines, and the failure that prevents (OOM mid-request or
thrashing) reaches a consumer as intermittent 5xx rather than as a config
error. Both ship disabled in the two purpose-built profiles, so the operator
enables exactly one.

The runtime is part of what a *deployment* chooses, alongside the weights. The
consumer contract above does not change: `CONTRACT_*_MODEL` /
`CONTRACT_*_API_BASE` re-point a role at a different backend with no edit to
`config/litellm/config.yaml`.

See **[docs/LLAMACPP.md](docs/LLAMACPP.md)** for weights acquisition, quant
selection, `fit` tuning, and five documented failure modes.

## Quick Start

### Prerequisites

- Linux server with NVIDIA GPU(s)
- Docker and Docker Compose
- NVIDIA Container Toolkit (nvidia-docker2)
- At least 16GB VRAM recommended

### Installation

1. Clone this repository:
```bash
git clone <your-repo-url> gpu-inference-stack
cd gpu-inference-stack
```

2. Choose a server profile and create your configuration:
```bash
# For high VRAM GPUs (48GB+)
cp servers/server-high-vram.env .env

# OR for default setup (8-24GB)
cp servers/server-default.env .env

# OR for multi-GPU setups
cp servers/server-multi-gpu.env .env
```

3. Edit `.env` to customize for your server:
```bash
nano .env
```

Key settings to review:
- `SERVER_NAME`: Unique identifier for this server
- `GPU_DEVICES`: Which GPUs to use (e.g., "0" or "0,1")
- `VLLM_MODEL`: Which model to load in vLLM
- `OLLAMA_PRELOAD_MODELS`: Models to preload in Ollama
- `LITELLM_MASTER_KEY`: Generate with `openssl rand -hex 32`
- `GRAFANA_ADMIN_PASSWORD`: Change from default!

4. Deploy the stack:
```bash
./scripts/deploy.sh
```

5. Wait for services to start (2-5 minutes), then verify:
```bash
./scripts/health-check.sh
```

### Model store — look on the NAS before the internet

Every box in the fleet serves the same handful of public checkpoints, and they
are large: Qwen3.6-35B-A3B in NVFP4 is **23.5 GB**. Downloading that per box
took **37 minutes** over this site's ~13 MB/s internet link; the same bytes come
off the NAS at **~92 MB/s**, about 4 minutes.

`make setup` step 6/6 therefore runs:

```bash
make model-store ARGS=sync
```

which, for every model the active profile names:

1. leaves it alone if it is already cached locally,
2. otherwise copies it from `MODEL_STORE_DIR` if it is there,
3. otherwise downloads it from Hugging Face **and publishes it to the store**,
   so the first box to need a checkpoint is the only one that pays for it.

```bash
make model-store                       # status: what the profile needs, and where each model is
make model-store ARGS=list             # what the store holds
make model-store ARGS=sync             # the above three-step reconciliation
./scripts/model-store.sh publish <repo>  # push one model you already have
./scripts/model-store.sh fetch <repo>    # pull one model without downloading
```

The store is itself a valid `HF_HOME` — `$MODEL_STORE_DIR/hub/models--<org>--<name>`,
huggingface_hub's own layout — so profiles keep naming plain repo ids
(`VLLM_MODEL=nvidia/Qwen3.6-35B-A3B-NVFP4`) and nothing downstream knows the NAS
exists.

**A missing store makes this slow, never broken.** A box where
`MODEL_STORE_DIR` is unset or not mounted says so and falls back to Hugging Face.

Three things worth knowing before changing it:

- **Publishing is a rename, not a lock.** The NAS is mounted `local_lock=all`,
  so `flock` on it is local to one host and two boxes would both believe they
  held it. Copies stage into a per-host, per-pid directory on the same
  filesystem and finish with a single atomic rename; losing that race costs one
  redundant copy and never a corrupt store.
- **The copy runs inside a root container.** vLLM populates the cache as root
  and huggingface_hub writes `trees/<sha>.json` mode 0600, so a plain host-side
  `rsync` fails with `Permission denied` and exit 23 — a *partial* transfer that
  discards everything it had already copied.
- **Attribute caching is 120s.** A model published seconds ago can be invisible
  to another box for a couple of minutes. The cost is a redundant download.

### Pre-flight Checks

`make start` runs comprehensive checks before starting containers. It auto-fixes common issues like:

- Container name conflicts from previous runs
- Port conflicts with old containers
- Missing volume directories

See [docs/preflight-checks.md](docs/preflight-checks.md) for details.

Skip checks: `SKIP_PREFLIGHT=1 make start`

## Usage

### Making Inference Requests

Once deployed, use the unified LiteLLM API (OpenAI-compatible):

```bash
# Chat completion
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "qwen2.5-7b-vllm",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# List available models
curl http://localhost:8080/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

### Available Models

Models are defined in `config/litellm/config.yaml`:

**Ollama Models:**
- `qwen2.5-7b-ollama`
- `qwen3.6-ollama`
- `gemma3-12b-ollama`
- `granite3.3-8b-ollama`

**vLLM Models:**
- `qwen2.5-7b-vllm`
- `qwen3.6-35b-vllm`

**Embeddings:**
- `bge-m3`

### Accessing Web Interfaces

- **LiteLLM UI**: http://localhost:8080/ui
- **Grafana**: http://localhost:3000 (default: admin/admin)
- **Prometheus**: http://localhost:9090

### Management Commands

```bash
# Deploy/start the stack
./scripts/deploy.sh

# Check health of all services
./scripts/health-check.sh

# Update to latest images
./scripts/update.sh

# Stop all services
./scripts/stop.sh

# Backup configuration
./scripts/backup-config.sh

# View logs
docker compose logs -f [service-name]
docker compose logs -f litellm
docker compose logs -f vllm
```

## Server Profiles

### Default Profile (`server-default.env`)
- Single GPU with 8-24GB VRAM
- Ollama with small models
- vLLM with 7B model
- GPU memory: 50%

### High VRAM Profile (`server-high-vram.env`)
- Single GPU with 48GB+ VRAM
- Ollama with multiple large models
- vLLM with 35B model
- Text embeddings enabled
- GPU memory: 65%

### A6000 48GB Profile (`server-a6000-48gb.env`)

The contract box. RTX A6000, `sm_86`, 48 GB VRAM, 251 GB RAM, no NVMe.
llama.cpp serves Qwen3-Next-80B-A3B (`UD-Q3_K_XL`, 33.19 GiB) behind all three
required `gpu/chat/*` roles at 4 slots x 32k. `gpu/chat/vision` is left
unserved — the model is text-only and there is no VRAM for a second one.

Both engines ship disabled; enable `ENABLE_LLAMACPP=true`. This profile also
sets `LITELLM_BIND_ADDR`, which is **required** on that box because another
service already holds `127.0.0.1:8080`.

### Blackwell 97GB Profile (`server-blackwell-97gb.env`)

The deep / long-context / vision box. RTX PRO 6000 Blackwell Max-Q, `sm_120`,
97 GB VRAM. llama.cpp serves Qwen3.8-Flash-Next (`UD-IQ3_XXS`, 76.3 GiB) behind
`gpu/chat/interactive` and `gpu/chat/vision` at 1 slot x 128k.

`gpu/chat/bulk` and `gpu/chat/fast` are deliberately **not** served here —
Flash-Next is effectively single-slot and `fast` carries a 60s timeout — so the
profile points them at the A6000 box instead. Cross-box role placement is what
the contract's server-addressed indirection is for.

### Multi-GPU Profile (`server-multi-gpu.env`)
- 2+ GPUs
- Tensor parallelism enabled in vLLM
- Multiple models across GPUs
- GPU memory: 70%

## Configuration

### Adding New Models

1. **For Ollama**: Pull the model, then add to `.env`:
```bash
docker exec ollama ollama pull llama3.1:70b
# Add to OLLAMA_PRELOAD_MODELS in .env
```

2. **For vLLM**: Update in `.env`:
```bash
VLLM_MODEL=meta-llama/Llama-3.1-70B-Instruct
VLLM_MODEL_NAME=llama3.1-70b
```

3. **Update LiteLLM config** in `config/litellm/config.yaml`

4. Restart services:
```bash
./scripts/update.sh
```

### Customizing Resource Limits

Edit `.env`:
```bash
# vLLM GPU memory
VLLM_GPU_MEMORY_UTILIZATION=0.70

# Ollama parallel requests
OLLAMA_NUM_PARALLEL=4

# Redis cache size
REDIS_MAXMEMORY=4gb
```

## Monitoring

### Grafana Dashboards

Access Grafana at `http://localhost:3000`:

1. **GPU Overview**: Real-time GPU utilization, temperature, memory
2. **LiteLLM Metrics**: Request rates, latency, errors
3. **System Metrics**: CPU, RAM, disk usage

### Prometheus Metrics

Available at `http://localhost:9090`:
- GPU metrics: `DCGM_FI_DEV_*`
- LiteLLM: `litellm_*`
- System: `node_*`

### Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f litellm
docker compose logs -f vllm

# Last 100 lines
docker compose logs --tail=100 ollama
```

## Deploying to Multiple Servers

### Method 1: Git Clone + Custom .env

On each server:
```bash
git clone <repo> gpu-inference-stack
cd gpu-inference-stack
cp servers/server-high-vram.env .env
# Edit .env for this server
./scripts/deploy.sh
```

### Method 2: Centralized Management

1. Create server-specific configs in repo:
```bash
servers/
  ├── prod-server-1.env
  ├── prod-server-2.env
  └── prod-server-3.env
```

2. On each server, symlink the config:
```bash
ln -s servers/prod-server-1.env .env
./scripts/deploy.sh
```

3. Push config changes to git, pull on servers, redeploy

## Troubleshooting

### Services won't start

```bash
# Check logs
docker compose logs

# Verify GPU access
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi

# Check NVIDIA runtime
docker info | grep -i runtime
```

### Out of GPU memory

1. Reduce `VLLM_GPU_MEMORY_UTILIZATION` in `.env`
2. Decrease `VLLM_MAX_MODEL_LEN` or `VLLM_MAX_NUM_SEQS`
3. Disable embeddings: `ENABLE_EMBEDDINGS=false`
4. Use smaller models

### Models not loading

```bash
# Check vLLM logs
docker compose logs vllm

# Check disk space
df -h

# Verify HuggingFace access
docker exec vllm ls -la /root/.cache/huggingface
```

### High latency

1. Enable prefix caching: `VLLM_ENABLE_PREFIX_CACHING=true`
2. Increase cache: `REDIS_MAXMEMORY=4gb`
3. Check GPU utilization in Grafana
4. Review `VLLM_MAX_NUM_SEQS` setting

## Production Recommendations

1. **Change default passwords** in `.env`
2. **Set up SSL/TLS** for external access (see nginx config)
3. **Enable authentication** on Prometheus/Grafana
4. **Regular backups** of `data/` and configs
5. **Monitor disk space** for model caches
6. **Set up alerting** in Prometheus
7. **Use Docker Compose override** for local customizations:
   ```bash
   # docker-compose.override.yml (gitignored)
   version: '3.8'
   services:
     vllm:
       environment:
         - CUSTOM_VAR=value
   ```

## Updating

```bash
# Update images
./scripts/update.sh

# Update configuration
git pull
./scripts/deploy.sh
```

## License

MIT

## Support

For issues and questions:
- Check `docs/` folder for detailed guides
- Review logs: `docker compose logs`
- Run health check: `./scripts/health-check.sh`

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test on a GPU server
4. Submit a pull request
