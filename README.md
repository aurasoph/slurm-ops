# Klone/HYAK vLLM Ops

Fork of `DeanLight/slurm-ops` focused on one workflow: run Qwen3-8B with
vLLM on a Klone GPU node and expose it on the laptop as an OpenAI-compatible
endpoint.

The source notebook is [nbs/02_vllm.ipynb](nbs/02_vllm.ipynb), exported to
[slurm_ops/vllm.py](slurm_ops/vllm.py). The quick-start notebooks are
[nbs/index.ipynb](nbs/index.ipynb) and [nbs/01_flow.ipynb](nbs/01_flow.ipynb).

## Quick Start

### 1. SSH config

Add a `klone-login` host to `~/.ssh/config`, replacing `<your-netid>`:

```sshconfig
Host klone-login
    HostName klone.hyak.uw.edu
    User <your-netid>
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10h
    ServerAliveInterval 60
```

Seed Duo once per working session:

```bash
ssh klone-login true
```

### 2. Sync the cluster-side files

```bash
ssh klone-login 'mkdir -p ~/slurm-ops/vllm'
rsync -a vllm/ klone-login:slurm-ops/vllm/
ssh klone-login 'chmod +x ~/slurm-ops/vllm/*.sh ~/slurm-ops/vllm/*.job ~/slurm-ops/vllm/bin/*'
```

### 3. Start Qwen

Public default resources are `account=stf`, `partition=gpu-l40s`, `gres=gpu:1`,
48G memory, four hours, and `--max-len 24576`:

```bash
./vllm/bin/vllm-up qwen klone-login
```

The max-length default is conservative for smoke tests; pass `--max-len 0` to
use the model default on larger GPUs.

For local testing with `amath` access:

```bash
./vllm/bin/vllm-up qwen-test klone-login --account amath --time 01:00:00
```

That uses the same L40S default as the public command. If Slurm leaves it
pending for `Resources`, cancel it and try the RTX 6000 checkpoint partition:

```bash
./vllm/bin/vllm-down qwen-test klone-login --local-port 8000
./vllm/bin/vllm-up qwen-test klone-login --account amath --partition ckpt --gres gpu:rtx6k:1 --time 01:00:00
```

HYAK exposes RTX 6000 GPUs as GRES `gpu:rtx6k`; `gpu-rtx6` is not a partition
name.

When ready, `vllm-up` prints the local endpoint. If `localhost:8000` is already
in use, it picks the next free port and prints that URL instead.

Readiness can take several minutes after Slurm allocates the node while
Qwen3-8B loads from the existing SIF/HF cache. That is normal and does not mean
the container is rebuilding.

```bash
export OPENAI_BASE_URL='http://localhost:8000/v1'
export OPENAI_API_KEY='dummy'
export VLLM_MODEL='Qwen/Qwen3-8B'
```

### 4. Ask Qwen something

```bash
./vllm/bin/vllm-chat --base-url http://localhost:8000/v1 "Reply with exactly: qwen-ready"
```

Use the `base_url` printed by `vllm-up`. The same endpoint works with any
OpenAI-compatible client. `vllm-chat` appends `/no_think` by default for Qwen3
and strips any residual `<think>` block from the printed smoke-test response.

### 5. Use the Lean agent

Once vLLM is running, `gcd-agent` can inspect a Lean/Lake project, build a
compact project context, list `sorry`/`admit` targets, and ask Qwen for a
candidate replacement.

Run it from this repo and point it at a Lean project:

```bash
OPENAI_BASE_URL=http://localhost:8000/v1 \
OPENAI_API_KEY=dummy \
VLLM_MODEL=Qwen/Qwen3-8B \
./agent/bin/gcd-agent --project /path/to/lean-project \
  --context "Prefer small patches. Preserve theorem statements exactly."
```

Inside the REPL:

```text
Tell me about the project
context        # show the project context sent to Qwen
list           # find sorry/admit targets
show 1         # inspect one target
ask 1          # ask Qwen for a replacement
try 1          # apply the cached candidate and lake build; reverts on failure
quit
```

For persistent project guidance, put instructions in the Lean repo:

```bash
mkdir -p /path/to/lean-project/.gcd
$EDITOR /path/to/lean-project/.gcd/agent.md
```

See [agent/README.md](agent/README.md) for the full agent workflow and command
reference.

### 6. Tear down

```bash
./vllm/bin/vllm-down qwen klone-login --local-port 8000
```

Use the same job name you passed to `vllm-up`, for example `qwen-test`. If
`vllm-up` printed a different local port, pass that value to `--local-port`.

## Python API

```python
from slurm_ops.vllm import make_slurm_args, vllm_up, vllm_chat, vllm_down

info = vllm_up("qwen", "klone-login")
vllm_chat("Reply with exactly: qwen-ready",
          base_url=info["base_url"],
          model=info["served_name"])
vllm_down("qwen", "klone-login", local_port=info["local_port"])

info = vllm_up(
    "qwen-test",
    "klone-login",
    slurm_args=make_slurm_args(account="amath", time_limit="01:00:00"),
)
```

## Debug

```bash
ssh klone-login -t tmux attach -t qwen
ssh klone-login tail -f ~/.vllm-discovery/qwen.log
ssh klone-login cat ~/.vllm-discovery/qwen.json
ssh klone-login squeue --me
```
