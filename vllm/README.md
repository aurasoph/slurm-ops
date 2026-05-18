# vllm/ — apptainer artifacts for the vLLM extension

The driver logic for bringing vLLM up lives in
[`slurm_ops/vllm.py`](../slurm_ops/vllm.py) (auto-exported from
[`nbs/02_vllm.ipynb`](../nbs/02_vllm.ipynb)) and **reuses the four
primitives from `slurm_ops.core` unchanged** — `start_or_connect`,
`job_stat`, `get_port_forwarding_command`, `update_ssh_node_config`.

This directory only holds the cluster-side container artifacts:

```
vllm/
├── vllm.def        # apptainer recipe (Bootstrap: docker, From: vllm/vllm-openai)
├── build-sif.job   # sbatch (one-off): pull → /gscratch/scrubbed/$USER/vllm.sif
├── serve.sh        # runs inside salloc on the compute node;
│                   # apptainer exec --nv vllm.sif python3 -m vllm…api_server
└── bin/
    ├── vllm-up     # thin shell stub: python -c 'from slurm_ops.vllm import vllm_up; vllm_up(...)'
    └── vllm-down   # thin shell stub for vllm_down(...)
```

## Usage

From a notebook (matches upstream slurm-ops's flow exactly):
```python
from slurm_ops.vllm import vllm_up, vllm_down
info = vllm_up("gcd", "klone-login")   # blocks until /v1/models is live
# … point any OpenAI client at info['base_url'] …
vllm_down("gcd", "klone-login")
```

From the shell (run from the repo root, or use the absolute path to `vllm/bin/vllm-up`):
```bash
./vllm/bin/vllm-up gcd klone-login         # same thing, no notebook needed
./vllm/bin/vllm-down gcd klone-login
```

## What this extension *adds* on top of upstream slurm-ops

Per the design constraint, **the only differences from upstream are**:

1. **Less manual work.** Upstream's `start_or_connect` and
   `get_port_forwarding_command` *print* commands you copy/paste; our
   `vllm_up` calls them with `return_cmd=True` and **executes** the
   strings. Same commands, no copy step.
2. **Containerized runtime.** The command inside the salloc shell is
   `apptainer exec --nv vllm.sif python3 -m vllm…api_server` instead of
   a bare command. The SIF gives a reproducible vLLM+CUDA stack
   independent of the host cluster's libraries.

Everything else — the ssh + tmux + salloc idiom, the ssh -L port
forwarding, the `Host klone-node` ProxyJump config that
`update_ssh_node_config` rewrites — is upstream's, used unmodified.

## How vllm_up wires the upstream primitives

```
                 resolve_sif(host) ── (build_sif if missing) ─┐
                                                              ▼
slurm_args = "--account=stf ... srun --pty serve.sh"          │
                                                              ▼
start_or_connect(job_name, host, slurm_args, return_cmd=True) │
   returns:  ssh -t klone-login "tmux new-session -A -s gcd '…salloc…'"
                                                              ▼
   ↓ we execute it (upstream prints; we run)
                                                              ▼
job_stat(job_name, host)  → (node, jobid)        [poll until allocated]
                                                              ▼
wait_for_discovery(job_name, host) → {"node","port","model",...}
                                                              ▼
get_port_forwarding_command(local_port, remote_port, host, node)
   returns:  ssh -N -f -L LOCAL:NODE.hyak.local:REMOTE klone-login
                                                              ▼
   ↓ we run an equivalent `ssh -O forward` against the ControlMaster
                                                              ▼
update_ssh_node_config(job_name, host)            [VSCode-attach bonus]
                                                              ▼
return {"base_url": "http://localhost:8000/v1", ...}
```

## Prereqs

The upstream slurm-ops ssh template gets you there:

```bash
cp ssh_config_templates/* ~/.ssh/
sed -i 's/deanlcs/<your-netid>/g' ~/.ssh/{config,klone-node-config,tillicum-node-config}
```

Then one Duo seed for the day:
```bash
ssh klone-login true
```

Subsequent `ssh klone-login` calls (including everything `vllm_up` does)
reuse the cached session via `ControlMaster auto + ControlPersist`.

## The `serve.sh` script

`serve.sh` is the only piece that runs on the GPU node. It:
1. Reads `MODEL` from env (default `Qwen/Qwen3-8B`).
2. Picks a free remote port.
3. Runs `apptainer exec --nv --bind <hf-cache>:/cache vllm.sif python3 -m vllm.entrypoints.openai.api_server --model … --host 0.0.0.0 --port …` in the background.
4. Polls `curl --noproxy '*' http://127.0.0.1:<port>/v1/models` until it answers (compute nodes route through a squid proxy; `--noproxy '*'` bypasses it for the local check).
5. Writes `~/.vllm-discovery/<job-name>.json` so `vllm_up` knows where to forward.
6. Blocks on the vLLM process; cleans up the discovery file on exit.

## Tweaks

| via env in `vllm-up`                  | what it does                  |
| ------------------------------------- | ----------------------------- |
| `--model HFREPO/Model`                | swap the served model         |
| `--local-port N`                      | bind localhost on a different port (default 8000) |
| `--slurm-args "--time=08:00:00 …"`    | override default salloc flags |

## Trade-off vs sbatch

We deliberately mirror upstream's `salloc + tmux` instead of running
vLLM as a long-running sbatch job. Consequence: **if the login node
reboots, the tmux session (and the salloc inside it) die**. With sbatch
the job would have survived. We chose the slurm-ops idiom for
debuggability (`ssh klone-login -t tmux attach -t <name>` shows live
vLLM output) and consistency with upstream.
