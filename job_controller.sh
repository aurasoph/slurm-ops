#!/bin/bash
# job_controller.sh - manages a persistent interactive slurm job named proxy_jump
#
# Usage:
#   CMD="command" bash job_controller.sh [SRUN_ARGS...]
#
# Examples:
#   bash job_controller.sh --qos=debug --gpus=1 --mem=200G --time=01:00:00
#   CMD="vllm serve meta-llama/Llama-3-8B --port 8555" bash job_controller.sh --qos=debug --gpus=1 --mem=200G --time=01:00:00

JOB_NAME="proxy_jump"
SRUN_ARGS="$@"
CMD="${CMD:-bash}"

JOB_INFO=$(squeue --me --name="$JOB_NAME" --states=RUNNING --format="%i %N %L" --noheader 2>/dev/null | head -1)

if [ -z "$JOB_INFO" ]; then
    echo "No existing $JOB_NAME job found. Starting interactive job..."
    echo "Running: srun --job-name=$JOB_NAME $SRUN_ARGS --pty $CMD"
    srun --job-name="$JOB_NAME" $SRUN_ARGS --pty $CMD
else
    JOB_ID=$(echo "$JOB_INFO" | awk '{print $1}')
    NODE=$(echo "$JOB_INFO" | awk '{print $2}')
    TIME_LEFT=$(echo "$JOB_INFO" | awk '{print $3}')
    echo "$JOB_NAME job already running:"
    echo "  Job ID:    $JOB_ID"
    echo "  Node:      $NODE"
    echo "  Time left: $TIME_LEFT"
fi
