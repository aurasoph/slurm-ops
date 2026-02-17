import socket
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


def port_forward(port, job_name="proxy_jump", host="tillicum-login", local_port=None):
    """Set up SSH port forwarding to a running slurm job's node. Returns local_port."""
    node = get_job_node(job_name, host)
    local_port = local_port or find_free_local_port()
    fwd = f"{local_port}:{node}.hyak.local:{port}"
    cmd = f"ssh -O forward -L {fwd} {host}"
    print(f"Run this command to set up port forwarding:\n  {cmd}")
    return local_port


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


def find_free_local_port():
    """Find an available local port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]
