import subprocess


def get_job_node(job_name="proxy_jump", host="tillicum-login"):
    """Get the node name of a running slurm job."""
    node = subprocess.check_output(
        ["ssh", host,
         f"squeue --me --name={job_name} --states=RUNNING --format=%N --noheader"],
        text=True
    ).strip().split("\n")[0]
    if not node:
        raise RuntimeError(f"No running job named '{job_name}' found")
    return node


def port_forward_cmd(port, job_name="proxy_jump", host="tillicum-login", local_port=None):
    """Print an ssh port-forward command for a running slurm job."""
    node = get_job_node(job_name, host)
    local_port = local_port or port
    cmd = f"ssh -O forward -L {local_port}:{node}.hyak.uw.edu:{port} {host}"
    print(cmd)
    return cmd


def run_on_job(cmd, job_name="proxy_jump", host="tillicum-login"):
    """Run a command on the compute node of a running slurm job and return its output."""
    job_id = subprocess.check_output(
        ["ssh", host,
         f"squeue --me --name={job_name} --states=RUNNING --format=%i --noheader"],
        text=True
    ).strip().split("\n")[0]
    if not job_id:
        raise RuntimeError(f"No running job named '{job_name}' found")
    result = subprocess.run(
        ["ssh", host, f"srun --overlap --jobid={job_id} bash"],
        input=cmd, capture_output=True, text=True
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    return result
