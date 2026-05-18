# vllm/

Cluster-side files and local wrappers for running Qwen3-8B on Klone through
vLLM.

The driver logic lives in [slurm_ops/vllm.py](../slurm_ops/vllm.py), exported
from [nbs/02_vllm.ipynb](../nbs/02_vllm.ipynb). This directory contains the
Apptainer recipe, the compute-node server script, and shell entrypoints.

```text
vllm/
├── vllm.def
├── build-sif.job
├── serve.sh
└── bin/
    ├── vllm-up
    ├── vllm-chat
    └── vllm-down
```

## Workflow

Sync the files to Klone:

```bash
ssh klone-login 'mkdir -p ~/slurm-ops/vllm'
rsync -a vllm/ klone-login:slurm-ops/vllm/
ssh klone-login 'chmod +x ~/slurm-ops/vllm/*.sh ~/slurm-ops/vllm/*.job ~/slurm-ops/vllm/bin/*'
```

Start the default `stf` allocation:

```bash
./vllm/bin/vllm-up qwen klone-login
```

For local testing with `amath`:

```bash
./vllm/bin/vllm-up qwen-test klone-login --account amath --time 01:00:00
```

Ask Qwen something:

```bash
./vllm/bin/vllm-chat --base-url http://localhost:8000/v1 "Reply with exactly: qwen-ready"
```

Stop the job:

```bash
./vllm/bin/vllm-down qwen klone-login --local-port 8000
```

If `localhost:8000` is already in use, `vllm-up` chooses the next free local
port and prints the exact chat and stop commands to use.

## Defaults

`vllm-up` defaults to:

```text
--account=stf --partition=gpu-l40s --gres=gpu:1 --cpus-per-task=8 --mem=48G --time=04:00:00
```

Resource flags can be overridden individually:

```bash
./vllm/bin/vllm-up qwen klone-login --account amath --time 01:00:00
```

or as a raw `salloc` resource string:

```bash
./vllm/bin/vllm-up qwen klone-login --slurm-args "--account=amath --partition=gpu-l40s --gres=gpu:1 --cpus-per-task=8 --mem=48G --time=01:00:00"
```

## What `vllm-up` does

1. Reuses an existing `/mmfs1/gscratch/scrubbed/$USER/vllm.sif`, or the shared
   fallback `/mmfs1/gscratch/scrubbed/aurasoph/vllm.sif`.
2. Builds a personal SIF with `build-sif.job` if neither exists.
3. Starts a detached tmux session on `klone-login`.
4. Runs `salloc ... srun --pty ~/slurm-ops/vllm/serve.sh`.
5. Waits for `serve.sh` to publish `~/.vllm-discovery/<job>.json`.
6. Opens a local SSH forward so the printed `http://localhost:<port>/v1`
   endpoint reaches the vLLM server on the compute node.

## Debug

```bash
ssh klone-login -t tmux attach -t qwen
ssh klone-login tail -f ~/.vllm-discovery/qwen.log
ssh klone-login cat ~/.vllm-discovery/qwen.json
ssh klone-login squeue --me
```
