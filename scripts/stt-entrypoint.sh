#!/bin/sh
# Entrypoint for the stt service: start speaches, install STT_MODEL, warm it.
#
# WHY THIS EXISTS. speaches 0.8.3 has no preload setting, and a transcription
# for a model that is not installed answers 404 ("is not installed locally")
# instead of downloading it. Without this, every fresh box would publish
# gpu/stt/whisper and fail every call until someone POSTed /v1/models by hand.
# The warm-up transcription then loads the weights, so the first real question
# does not pay the 13 s cold load measured on ddai3 (2026-10-11). With
# WHISPER__TTL=-1 the model then stays loaded.
#
# The server keeps running if the install fails: the healthcheck reports it
# unhealthy, and the logs say why.
# Spec: project-deepdarshak/.claude/specs/2026-10-11-voice-questions-for-the-advisor.md (REQ-STT-01)
set -u

uvicorn --factory speaches.main:create_app &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT

python3 - "${STT_MODEL:?STT_MODEL is required}" <<'PY'
import sys, time, urllib.parse, urllib.request
model = sys.argv[1]
base = "http://localhost:8000"
for _ in range(120):
    try:
        urllib.request.urlopen(f"{base}/health", timeout=2)
        break
    except Exception:
        time.sleep(1)
try:
    req = urllib.request.Request(f"{base}/v1/models/{urllib.parse.quote(model, safe='/')}", method="POST")
    urllib.request.urlopen(req, timeout=3600)
    print(f"stt-entrypoint: {model} installed", flush=True)
except Exception as e:
    print(f"stt-entrypoint: could not install {model}: {e}", file=sys.stderr, flush=True)
PY
python3 /healthprobe.py --url http://localhost:8000/v1/audio/transcriptions \
    --kind transcription --model "$STT_MODEL" --timeout 300 \
    && echo "stt-entrypoint: $STT_MODEL warm"

wait "$pid"
# A TERM interrupts the first wait; the second lets uvicorn finish shutting down.
wait "$pid"
