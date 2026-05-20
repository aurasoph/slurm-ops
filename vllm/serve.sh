#!/bin/bash
# serve.sh — run *inside* a salloc'd shell on a GPU compute node to start a
# vLLM OpenAI-compatible server and publish a discovery file.
#
# Not an sbatch script. The slurm-ops idiom (see start_or_connect) is to
# `salloc … <this script>` from a tmux session on the login node; the
# allocation lives as long as tmux + the salloc'd command do.
#
# Override via env:
#   MODEL          HF model id (default: Qwen/Qwen3-8B)
#   SERVED_NAME    --served-model-name (default: $MODEL)
#   MAX_LEN        --max-model-len (default: 24576; conservative smoke-test context)
#   VLLM_EXTRA     extra args to vllm api_server
#   VLLM_SIF       SIF path (default: /mmfs1/gscratch/scrubbed/$USER/vllm.sif)
#   HF_CACHE       HF cache dir (default: /mmfs1/gscratch/scrubbed/$USER/.hf_cache)

set -euo pipefail

JOB_NAME="${SLURM_JOB_NAME:-vllm}"
G_BASE="/mmfs1/gscratch/scrubbed/$USER"
SIF="${VLLM_SIF:-$G_BASE/vllm.sif}"
HF_CACHE="${HF_CACHE:-$G_BASE/.hf_cache}"
DISC_DIR="${VLLM_DISCOVERY_DIR:-$HOME/.vllm-discovery}"
DISC_FILE="$DISC_DIR/${JOB_NAME}.json"
LOG_FILE="$DISC_DIR/${JOB_NAME}.log"

mkdir -p "$HF_CACHE" "$DISC_DIR"

# Tee everything so the user gets live tmux output AND a persistent log.
exec > >(tee -a "$LOG_FILE") 2>&1

MODEL="${MODEL:-Qwen/Qwen3-8B}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"
MAX_LEN="${MAX_LEN:-24576}"
VLLM_EXTRA="${VLLM_EXTRA:-}"

if [ ! -f "$SIF" ]; then
    echo "[vllm] SIF not found: $SIF" >&2
    echo "[vllm] Build it first via vllm-up (which auto-runs build-sif.job)." >&2
    exit 2
fi

command -v apptainer >/dev/null 2>&1 || module load apptainer >/dev/null 2>&1

NODE="$(hostname -s)"
PORT="$(shuf -i 20000-60000 -n 1)"
JOB_ID="${SLURM_JOB_ID:-unknown}"

echo "[vllm] $(date -Iseconds)"
echo "[vllm] node       : $NODE"
echo "[vllm] port       : $PORT"
echo "[vllm] job        : $JOB_NAME ($JOB_ID)"
echo "[vllm] model      : $MODEL  (served as $SERVED_NAME)"
echo "[vllm] max len    : $MAX_LEN"
echo "[vllm] sif        : $SIF"
echo "[vllm] hf cache   : $HF_CACHE"
echo "[vllm] discovery  : $DISC_FILE"
echo "[vllm] log        : $LOG_FILE"
echo

cleanup() {
    rm -f "$DISC_FILE"
    [ -n "${VLLM_PID:-}" ] && kill "$VLLM_PID" 2>/dev/null || true
}
trap cleanup EXIT

EXTRA_ARGS=()
[ -n "$MAX_LEN" ] && EXTRA_ARGS+=(--max-model-len "$MAX_LEN")
# shellcheck disable=SC2206
EXTRA_ARGS+=($VLLM_EXTRA)

# Start vLLM in the background so we can poll for readiness, then publish.
# The vllm/vllm-openai image symlinks `python` to `python3` in PATH only
# under its conda env (/usr/bin/python doesn't exist); use python3 explicitly.
apptainer exec --nv \
    --bind "$HF_CACHE:/cache" \
    --env HF_HOME=/cache \
    --env HF_HUB_ENABLE_HF_TRANSFER=1 \
    --env VLLM_NO_USAGE_STATS=1 \
    "$SIF" \
    python3 -m vllm.entrypoints.openai.api_server \
        --model "$MODEL" \
        --served-model-name "$SERVED_NAME" \
        --host 0.0.0.0 \
        --port "$PORT" \
        "${EXTRA_ARGS[@]}" \
    &
VLLM_PID=$!

# --noproxy '*' is required: klone compute nodes set http_proxy=klone-dip1
# for HF downloads, and 127.0.0.1 is not in $no_proxy, so without it our
# health checks get routed to the squid proxy and return 503.
echo "[vllm] waiting for http://127.0.0.1:$PORT/v1/models ..."
for i in $(seq 1 360); do
    if curl -sf --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
        echo "[vllm] healthy after ${i}*5s"
        break
    fi
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        echo "[vllm] vLLM exited before becoming healthy" >&2
        wait "$VLLM_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 5
done

if ! curl -sf --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null; then
    echo "[vllm] never became healthy" >&2
    kill "$VLLM_PID" 2>/dev/null || true
    exit 1
fi

# Publish discovery atomically.
tmp="${DISC_FILE}.tmp.$$"
cat > "$tmp" <<JSON
{"node": "$NODE", "port": $PORT, "model": "$MODEL", "served_name": "$SERVED_NAME", "max_len": "$MAX_LEN", "job_id": "$JOB_ID", "job_name": "$JOB_NAME"}
JSON
mv -f "$tmp" "$DISC_FILE"

cat <<BANNER
============================================================
  vLLM READY
  node         : $NODE
  port         : $PORT
  model        : $MODEL  (served as: $SERVED_NAME)
  max len      : $MAX_LEN
  discovery    : $DISC_FILE
  log          : $LOG_FILE
  attach       : ssh klone-login -t tmux attach -t $JOB_NAME
============================================================
BANNER

wait "$VLLM_PID"
