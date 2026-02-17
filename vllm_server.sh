#!/bin/bash
# vllm_server.sh - Start a vLLM server on a compute node
#
# Required env vars:
#   VLLM_MODEL   - model name (e.g. Qwen/Qwen2.5-1.5B-Instruct)
#   VLLM_PORT    - port to serve on
#   VLLM_API_KEY - API key for authentication
#
# Optional env vars:
#   VLLM_EXTRA_ARGS - additional args passed to vllm serve
#
# Usage (via run_on_job on existing proxy_jump allocation):
#   run_on_job("VLLM_MODEL=... VLLM_PORT=... VLLM_API_KEY=... nohup bash ~/vllm_server.sh &")

module load gcc/13.4.0
module load cuda/13.0.0

echo "Starting vLLM server on $(hostname):${VLLM_PORT} with model ${VLLM_MODEL}"
cd "${CHDIR}" 
exec vllm serve "${VLLM_MODEL}" \
    --port "${VLLM_PORT}" \
    --api-key "${VLLM_API_KEY}" \
    ${VLLM_EXTRA_ARGS}
