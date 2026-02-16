#!/bin/bash
# job_controller.sh - manages a persistent interactive slurm job named proxy_jump

JOB_NAME="proxy_jump"

JOB_INFO=$(squeue --me --name="$JOB_NAME" --states=RUNNING --format="%i %N %L" --noheader 2>/dev/null | head -1)

if [ -z "$JOB_INFO" ]; then
    echo "No existing $JOB_NAME job found. Starting interactive job..."
    srun --job-name="$JOB_NAME" --pty bash
else
    JOB_ID=$(echo "$JOB_INFO" | awk '{print $1}')
    NODE=$(echo "$JOB_INFO" | awk '{print $2}')
    TIME_LEFT=$(echo "$JOB_INFO" | awk '{print $3}')
    echo "$JOB_NAME job already running:"
    echo "  Job ID:    $JOB_ID"
    echo "  Node:      $NODE"
    echo "  Time left: $TIME_LEFT"
fi
