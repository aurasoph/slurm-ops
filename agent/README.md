# agent/ - Lean project context + vLLM REPL

Driver logic lives in [`slurm_ops/agent.py`](../slurm_ops/agent.py)
(documented by [`nbs/03_agent.ipynb`](../nbs/03_agent.ipynb)). This directory
just holds the shell entrypoint and the `.env` template.

```
agent/
├── README.md
├── .env.example      # copy to .env (gitignored), set LEAN_REPO_PATH
├── .gitignore        # ignores .env
└── bin/
    └── gcd-agent     # thin shell stub: invokes slurm_ops.agent.main
```

## One-time

```bash
cp agent/.env.example agent/.env
# edit agent/.env: set LEAN_REPO_PATH to the absolute path of your Lean project
```

Optional project guidance lives in the Lean repo, not in `slurm-ops`:

```bash
mkdir -p /path/to/lean-project/.gcd
$EDITOR /path/to/lean-project/.gcd/agent.md
```

Use that file for persistent context such as project goals, preferred proof
style, constraints, and what the agent should avoid changing. `gcd-agent`
also looks for `.gcd/context.md`, `.gcd/instructions.md`, and `AGENTS.md`.

## Usage

In a shell where `vllm-up qwen klone-login` has already printed the vLLM
exports (i.e. `OPENAI_BASE_URL=http://localhost:8000/v1`):

```bash
./agent/bin/gcd-agent
```

You land in a REPL:

```
  gcd-agent  —  slash-command REPL over a Lean project + vLLM
  project    : /home/.../lean-gcd-convex-opt
  endpoint   : http://localhost:8000/v1
  model      : Qwen/Qwen3-8B

  commands   : context, chat QUESTION, instructions, list, show N,
               ask N, try N, build [MODULE], env, quit
               (you can also just type a project question)

gcd> Tell me about the project
[agent] asking vLLM about the project...
...

gcd> list
[agent] scanning … via Lean LSP...
   1  ConvexOpt/Ch21_Lines.lean:29   lineThroughTwoPoints
   2  ConvexOpt/Ch21_Lines.lean:33   convexCombo
   …

gcd> show 1
--- ConvexOpt/Ch21_Lines.lean  (lines 28-31, decl: lineThroughTwoPoints) ---
theorem lineThroughTwoPoints (a b : Point) : ... := by
  sorry

gcd> ask 1
[agent] asking vLLM about #1 lineThroughTwoPoints...
[agent] 142 tokens; model=Qwen/Qwen3-8B
--- candidate ---
theorem lineThroughTwoPoints (a b : Point) : ... := by
  ...
--- (use `try 1` to apply + lake build) ---

gcd> try 1
[agent] lake build ConvexOpt.Ch21_Lines...
[agent] BUILD FAILED (rc=1); reverted Ch21_Lines.lean.
  | error: …

gcd> quit
```

## Commands

| command | what it does |
|---|---|
| `context` | print the Lean project context that will be sent to vLLM |
| `chat QUESTION` | ask vLLM a free-form question about the project context |
| free-form text | same as `chat`; for example `Tell me about the project` |
| `instructions` | show persistent project instructions and session instructions |
| `instructions TEXT` | append session-only guidance for future `ask` calls |
| `instructions @PATH` | load extra session guidance from a file |
| `refresh_context` | rescan Lake metadata, README, git status, and instruction files |
| `list` | LSP-scan the project for sorrys; cache them as a numbered list |
| `show N` | print the declaration around sorry #N + ~5 lines of context either side |
| `ask N` | send sorry #N plus project context/instructions to vLLM; cache the candidate; print it |
| `try N` | splice the cached candidate into the file; `lake build <Module>`; revert on failure |
| `build [MOD]` | run `lake build` for the whole project (or `lake build MOD`) |
| `env` | print LEAN_REPO_PATH / OPENAI_BASE_URL / OPENAI_API_KEY / VLLM_MODEL |
| `quit` / `exit` / Ctrl-D | leave |

## Config resolution order

For `LEAN_REPO_PATH`:
1. `--project PATH` flag
2. `$LEAN_REPO_PATH` already in your shell
3. `.env` next to where you invoked `gcd-agent` (cwd, then walking upward)

For project instructions:
1. `--instructions PATH`
2. `$LEAN_AGENT_INSTRUCTIONS`
3. first existing repo-local files among `.gcd/agent.md`,
   `.gcd/context.md`, `.gcd/instructions.md`, and `AGENTS.md`

For session-only instructions:
1. `--context "..."` flags
2. `$LEAN_AGENT_CONTEXT`
3. the REPL command `instructions TEXT`

For the vLLM endpoint: `$OPENAI_BASE_URL` / `$OPENAI_API_KEY` / `$VLLM_MODEL`.
If unset, `gcd-agent` uses `http://localhost:8000/v1`, `dummy`, and
`Qwen/Qwen3-8B`, matching the default `vllm-up` endpoint.

## What context gets sent to vLLM

Each `chat QUESTION` and `ask N` includes:

- Lake metadata: lakefile kind, package name, toolchain, dependencies
- source roots, Lean file count, and a lightweight sorry/admit count
- git branch and short status
- top-level README excerpt, if present
- repo-local instructions from `.gcd/agent.md` or equivalent files
- session instructions added with `--context` or the `instructions` command
- target file imports, declaration signature, surrounding context, and Lean
  diagnostic text

## What `try N` actually does

1. `_snapshot(target_file)` — copy to a temp dir.
2. `splice(text, hit, candidate)` — replace lines `hit.decl_range[0]..[1]`
   with the candidate. The candidate is expected to be the full replacement
   declaration with the same statement and a filled proof, not just the proof
   term.
3. `lake build <Module>` — targeted build of just the file's module, much
   faster than the whole project.
4. If `rc != 0`, copy the snapshot back. Print the last 20 lines of the
   error.

Whole-file revert is intentionally aggressive — easier to reason about
than "patch just the relevant lines" when the LLM's output formatting
varies. Granularity can tighten later if it becomes a problem.
