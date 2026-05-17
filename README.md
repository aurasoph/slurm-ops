# GCD fork of slurm-ops

This is the GCD project's fork of [DeanLight/slurm-ops](https://github.com/DeanLight/slurm-ops).

**The only changes from upstream:**

1. A new nbdev notebook
   [`nbs/02_vllm.ipynb`](nbs/02_vllm.ipynb) (with its auto-exported
   [`slurm_ops/vllm.py`](slurm_ops/vllm.py)) that adds `vllm_up` /
   `vllm_down`. These **reuse the four primitives from `slurm_ops.core`
   unchanged** (`start_or_connect`, `job_stat`,
   `get_port_forwarding_command`, `update_ssh_node_config`); they just
   *execute* the commands those functions normally print and chain them
   end-to-end so there are fewer things to copy/paste.
2. A new [`vllm/`](vllm/) directory with the apptainer recipe
   (`vllm.def`), the SIF build sbatch (`build-sif.job`), and the
   compute-node entrypoint (`serve.sh`) that runs
   `apptainer exec --nv vllm.sif python3 -m vllm…api_server`.

No upstream files were modified.

See [`vllm/README.md`](vllm/README.md) for what `vllm_up` does step by
step and how each call lines up with an upstream primitive.

---

## End-to-end test: does Qwen3-8B answer over vLLM?

This is the test someone with klone access should be able to follow on
a fresh laptop, with no further questions. About 15 minutes the first
time (because `vllm_up` builds the SIF on klone if it isn't there yet),
~2 minutes on subsequent runs.

### 1. Prereq: laptop can `ssh klone-login` (one time, ever)

Follow upstream's ssh config setup (the section below this one, titled
*Tillicum Slurm Ops*). Specifically:

```bash
cp ssh_config_templates/* ~/.ssh/
# replace 'deanlcs' with your NetID in all three:
sed -i "s/deanlcs/$USER/g" ~/.ssh/{config,klone-node-config,tillicum-node-config}
```

Then seed Duo for the day:

```bash
ssh klone-login true
# NetID password, Duo push, accept
ssh klone-login true   # second call should be silent and instant
```

(You may see `Could not open a connection to your authentication agent`
on every ssh — that's a benign WSL warning, not an error. Run
`eval "$(ssh-agent -s)"` if you want it gone.)

### 2. Prereq: the fork is somewhere the laptop's Python can import

```bash
git clone https://github.com/aurasoph/slurm-ops.git ~/projects/gcd/slurm-ops
```

(Optional, for notebook use:)
```bash
cd ~/projects/gcd/slurm-ops && uv sync
```

The shell stubs in `vllm/bin/` resolve `slurm_ops` from the repo root
themselves — they don't need `uv sync`.

### 3. Push the cluster-side artifacts to klone (one time)

`vllm_up` will build the SIF on klone automatically, but it needs the
recipe + sbatch + serve.sh sitting in your klone home:

```bash
rsync -av --delete \
    ~/projects/gcd/slurm-ops/vllm/ \
    klone-login:projects/gcd/slurm-ops/vllm/
ssh klone-login "chmod +x ~/projects/gcd/slurm-ops/vllm/*.job \
                                   ~/projects/gcd/slurm-ops/vllm/*.sh \
                                   ~/projects/gcd/slurm-ops/vllm/bin/*"
```

### 4. Smoke test: imports + cluster reachability

```bash
cd ~/projects/gcd/slurm-ops
python3 -c "
from slurm_ops.vllm import sif_exists
print('sif on klone?', sif_exists('klone-login'))
"
```

Expected:
- `sif on klone? True` if you (or a prior run) have already built it
- `sif on klone? False` otherwise — `vllm_up` will build it for you in step 5

### 5. Bring up vLLM and hit the endpoint

```bash
~/projects/gcd/slurm-ops/vllm/bin/vllm-up gcd klone-login
```

You should see in order:

```
No running job 'gcd' found. Starting salloc...                  # from upstream start_or_connect
[vllm] launching: ssh -t klone-login "tmux new-session -A -d -s gcd 'salloc … srun --pty …/serve.sh'"
[vllm] waiting for salloc to allocate a GPU node...
[vllm] allocated: job <jobid> on g3xxx                          # from upstream job_stat
[vllm] waiting for $HOME/.vllm-discovery/gcd.json on klone-login (up to 30 min)...
   # ~2-5 min: model load + CUDA graph capture on the L40s
ssh -N -f -L 8000:g3xxx.hyak.local:NNNNN klone-login            # from upstream get_port_forwarding_command
[vllm] opening forward: ssh -O forward -L 8000:g3xxx.hyak.local:NNNNN klone-login
Updated ~/.ssh/klone-node-config: Hostname → g3xxx              # from upstream update_ssh_node_config

============================================================
  vLLM ready: Qwen/Qwen3-8B on g3xxx:NNNNN
  base_url = http://localhost:8000/v1
  export OPENAI_BASE_URL='http://localhost:8000/v1'
  export OPENAI_API_KEY='dummy'
  export VLLM_MODEL='Qwen/Qwen3-8B'
============================================================
```

From another terminal, prove Qwen actually responds:

```bash
# 1. The vLLM endpoint is reachable
curl -s http://localhost:8000/v1/models | python3 -m json.tool
# Expect: {"object":"list","data":[{"id":"Qwen/Qwen3-8B", ...}]}

# 2. Qwen3-8B can complete a prompt
curl -s http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
          "model": "Qwen/Qwen3-8B",
          "messages": [{"role":"user","content":"What is 12*7? Answer with just the number."}],
          "max_tokens": 50,
          "temperature": 0
        }' \
    | python3 -m json.tool
# Expect: choices[0].message.content contains reasoning that ends with "84"
```

**That's the test.** Two curls returning valid JSON = Qwen on vLLM
works end-to-end from your laptop.

### 6. Bonus: VSCode / direct SSH onto the compute node

`vllm_up` called `update_ssh_node_config`, which rewrote
`~/.ssh/klone-node-config` with the live compute node's hostname.
Confirm:

```bash
ssh klone-node hostname        # should print g3xxx
```

In VSCode: *Remote-SSH → Connect to Host → `klone-node`* attaches an
editor session to the GPU node directly. (This is upstream slurm-ops's
feature, unchanged.)

### 7. Tear down

```bash
~/projects/gcd/slurm-ops/vllm/bin/vllm-down gcd klone-login
# scancel + tmux kill-session + ssh -O cancel
```

### Debug toolbox

If something hangs partway through, all of these are direct (no Pi, no
extras) and safe to run at any time:

```bash
ssh klone-login squeue --me                              # what's allocated
ssh klone-login -t tmux attach -t gcd                    # live vLLM stdout (Ctrl+B D to detach)
ssh klone-login tail -f ~/.vllm-discovery/gcd.log        # persistent serve.sh log
ssh klone-login cat ~/.vllm-discovery/gcd.json           # discovery (node, port, model)
ssh klone-login ls -lh /mmfs1/gscratch/scrubbed/$USER/vllm.sif   # is the SIF there?
```

---

# Tillicum Slurm Ops (upstream README below)


<!-- WARNING: THIS FILE WAS AUTOGENERATED! DO NOT EDIT! -->
<!-- (Above this block was added by the GCD fork; nbdev will not touch it.) -->

## Get this nb working

make sure you are running this notebook in a uv env that has this repo
installed.

The easiest way to do so would be to:

``` bash
# clone this repo
git clone https://github.com/DeanLight/slurm-ops

# cd into it
cd slurm-ops

# create a uv env for it
uv sync

# open this repo in vscode and select the venv you created as the kernel for the notebook
```

Now the import cell should run

``` python
from slurm_ops.core import (
    start_or_connect,
    job_stat,
    update_ssh_node_config,
    find_free_port,
    get_port_forwarding_command,
)
```

These commands print the commands that you wanna put in your terminal to
interact with tillicum

## 1. SSH Config Setup

The `ssh_config_templates/` directory contains two files that need to go
into your `~/.ssh/`:

- **`config`** - Main SSH config with hosts for `klone-login`,
  `klone-node`, `tillicum-login`, and `moana`. Uses `ControlMaster` for
  persistent connections so you only authenticate once.
- **`klone-node-config`** - Included by the main config for the
  `klone-node` host. Contains the `ProxyJump` setup so you can SSH
  directly to a compute node through the login node.

**Before copying**, edit `ssh_config_templates/config` and replace
`deanlcs` with your own username.

Then copy them into place:

``` python
# ! cp ../ssh_config_templates/* ~/.ssh/
# ! for f in config klone-node-config tillicum-node-config; do sed -i '' 's/deanlcs/<YOUR_CS_ID>/g' ~/.ssh/"$f"; done
```

## 2. First Login to Tillicum

Test that your SSH config works. The first time you connect you’ll need
to authenticate (2FA, password, etc). After that, `ControlMaster` keeps
the connection alive so subsequent SSH commands reuse it without
re-authenticating.

``` python
! ssh tillicum-login echo "Connected successfully"
```

    Connected successfully

## Getting an interactive job, with a terminal and vscode access

Running this command will get us a tmux pane with an allocation for a
compute node with a single gpu for an hour. If its already running, we
will get the command to reattach to the tmux server

``` python
job_name = "remote_dev"
slurm_host = "tillicum-login"
start_or_connect(job_name, slurm_host,
    slurm_args="--qos=debug --gpus=1 --cpus-per-task=8 --mem=200G --time=01:00:00")
```

    No running job 'remote_dev' found. Starting salloc...
    Run this in your terminal:
    ssh -t tillicum-login "tmux new-session -A -s remote_dev 'salloc --job-name=remote_dev --qos=debug --gpus=1 --cpus-per-task=8 --mem=200G --time=01:00:00'"

This is how we can get info about our job

``` python
node, job_id = job_stat(job_name, slurm_host)
```

    Job 'remote_dev' status on tillicum-login:
      Job ID:    62526
      Node:      g004
      Time left: 31:25
      Partition: gpu-h200

    Useful commands (run these on the login node or via ssh):
      # Get a shell on the compute node:
      ssh -t tillicum-login 'srun --jobid=62526 --overlap --pty bash'
      # Cancel the job:
      ssh tillicum-login 'scancel 62526'
      # View job details:
      ssh tillicum-login 'scontrol show job 62526'

If we want to have a remote vscode on our node, we need to change our
ssh config based on the compute node our job is on

``` python
update_ssh_node_config(job_name,host=slurm_host)
```

    Updated /Users/deanlight/.ssh/tillicum-node-config: Hostname → g004

    'g004'

``` python
! cat /Users/deanlight/.ssh/tillicum-node-config
```

    Host tillicum-node
      User deanlcs
      Hostname g007               
      ProxyJump tillicum-login

you will note that now the hostname changed in the ssh config.

Now, if you

- installed the remote development [vscode
  extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.vscode-remote-extensionpack)
- you can look for the command `Remote-SSH: connect to host` and
- you can choose to connect to tillicum-node.
- It will ask for your password which is your uwid password
- Then it will spin a vscode server on the compute node with a new
  vscode window for you to use.

> Note: the first time you do this, it could take some time for the
> vscode server to install itself on your home dir in tillicum

Now, you can controll the job via the tmux terminal, cancel it by
exiting the terminal etc, and you do the actual work using the vscode
interface.

## 4. First-Time Setup on a Compute Node

Ok, now that we have access to a strong compute server, we can get ready
to do some knarly ML shit.

here are a couple of things you want to do on the compute server.

> Note: since the file system is shared for all server, all file changes
> you make here, including installations, will persist to other slurm
> jobs. They will also persist to the login node.

### Scratch directory

Home directories have limited space. Create a scratch directory and
symlink `~/.cache` to it so that tools like `uv` and `huggingface-cli`
cache to the larger filesystem.

``` bash

mkdir -p /gpfs/scrubbed/$USER/cache
chmod 700 /gpfs/scrubbed/$USER
ln -sf /gpfs/scrubbed/$USER/cache ~/.cache
```

### Install direnv

Working with project specific env vars is a hassle, lets install direnv.
This allows you to set up a `.envrc` file in different directories, and
each time you `cd` in/out of directories, it will change your env vars
to have all env vars defined in `.envrc` files in directories in your
current path.

``` bash
curl -sfL https://direnv.net/install.sh | bash
```

Now follow the config instructions it gives you, they should be
something like: \> hook it into your shell (.bashrc or .zshrc) by adding
eval “\$(direnv hook bash/zsh)”. Finally, create a .envrc file in your
project directory, add environment variables, and run direnv allow set
UV

### Install uv (Python package manager)

``` bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

This installs to `~/.local/bin`. Make sure it’s on your PATH (the
installer adds it to `.bashrc` automatically).

Now we need to make sure that `uv` doesnt install big packages into our
home directory, so lets put the following into an `envrc` in our home
directory.

``` bash
# Add to ~/.envrc
export UV_CACHE_DIR="/gpfs/scrubbed/$USER/cache/uv"
export UV_PYTHON_INSTALL_DIR="/gpfs/scrubbed/$USER/cache/uv/python"

# Then install a Python version once:
uv python install 3.12

# and you can look at your cache dirs to see stuff was installed outside of your homedir
```

### Install GitHub CLI

To make auth to github more sensible, we can install the github cli.
Since we dont have `apt-get` style access on tillicum, we install it by
downloading the binaries and putting them in our local `bin` dir.

``` bash
VERSION="2.86.0"
ARCH="amd64"
```

``` bash
mkdir -p ~/.local/bin && \
cd /tmp && \
wget -q "https://github.com/cli/cli/releases/download/v${VERSION}/gh_${VERSION}_linux_${ARCH}.tar.gz" -O gh.tar.gz && \
tar -xzf gh.tar.gz && \
cp gh_${VERSION}_linux_${ARCH}/bin/gh ~/.local/bin/ && \
chmod +x ~/.local/bin/gh && \
rm -rf gh_${VERSION}_linux_${ARCH} gh.tar.gz
```

Then authenticate. You’ll need a [personal access
token](https://github.com/settings/tokens):

``` bash
gh auth login
```

### Load CUDA (needed each job)

This is not a one-time step – you need to run this every time you start
a new job that needs cuda in tillicum. Yeah, it sucks, I agree.

``` bash
module load gcc/13.4.0
module load cuda/13.0.0
```

When running batch jobs via shell scripts, you can put it in the
beggining of the scripts.

## 5. Port Forwarding - vllm example

Many times, you’ll want to run some service on tillicum and communicate
with it from your pc. A classic example is running a vllm inference
server on tillicum, so you can use it to do all the llm inference time
tasks on code your are developing on your laptop.

To do so, we will show an example of spinning up a vllm server on a
tillicum node, and then port forwarding so you can ask for completion on
your local laptop.

On your compute node, do the following:

``` bash

# lets make an example project, in practice, this will stand in for a repo you are developing and clone into on tillicum


## Project Setup
# make a new directory
project_name=vllm_worker

mkdir $project_name
cd $project_name

# set up env vars for uv to use your cache directory to install the env
project_venv_dir=${UV_CACHE_DIR}/${project_name}
mkdir $project_venv_dir
ln -sf $project_venv_dir$ .venv

# start a new uv project and add vllm to it
uv init
uv python pin 3.12
uv add vllm llguidance
```

Now create an `.envrc` file with the following content, and then allow
it using `direnv allow`

``` bash
export PORT=8555
export MODEL=Qwen/Qwen2.5-1.5B-Instruct
export API_KEY="123_secret_password"
```

And create a script called `start_vllm.sh` with the content:

``` bash
#!/bin/bash

if [ -z "$MODEL" ]; then
    echo "Error: MODEL is not set" >&2
    exit 1
fi
if [ -z "$PORT" ]; then
    echo "Error: PORT is not set" >&2
    exit 1
fi
if [ -z "$API_KEY" ]; then
    echo "Error: API_KEY is not set" >&2
    exit 1
fi

module load gcc/13.4.0
module load cuda/13.0.0


vllm serve $MODEL --port $PORT --api-key $API_KEY \
     --enable-prefix-caching \
     --seed 42
```

Now, when you login to the cluster and want to run a vllm server, cd to
the project directory and run:

``` bash
uv run bash start_vllm.sh
```

Once your vllm server is up, we need to do the port forwarding from the
node, to our local computer

``` python
local_port = find_free_port(above=8000)
_=get_port_forwarding_command(local_port=8555, remote_port=vllm_port, node=node, host=slurm_host)
```

    ssh -N -f -L 8555:g007.hyak.local:8555 tillicum-login

Once we have the port forwaring working, we can talk to our vllm server
locally

``` python
import os
from openai import OpenAI
from dotenv import load_dotenv

load_dotenv('../.envrc') # make sure you have a similar .envrc on your local machine

api_key = os.environ['API_KEY']
model = os.environ['MODEL']

openai_api_base = f"http://localhost:{local_port}/v1"
client = OpenAI(
    api_key=api_key,
    base_url=openai_api_base,
)
completion = client.completions.create(
    model=model,
    prompt="who are you?",
)
print("Completion result:", completion)
```

And there you go!

To see only the repeating instruction, see the notebook
`nbs/01_flow.ipynb`
