#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
import tempfile
import time
import shlex
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
IGNORE_NAMES = {
    ".git",
    ".mutate4lua",
    "__pycache__",
    ".pytest_cache",
}
def lua_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace('"', '\\"')
    return f'"{escaped}"'
def to_lua(value, indent=0):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return lua_quote(value)
    if isinstance(value, list):
        parts = [to_lua(item, indent + 2) for item in value]
        return "{ " + ", ".join(parts) + " }"
    if isinstance(value, dict):
        parts = []
        for key in sorted(value):
            rendered_key = key if key.isidentifier() else f'[{lua_quote(key)}]'
            parts.append(f"{rendered_key} = {to_lua(value[key], indent + 2)}")
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(f"unsupported type: {type(value)!r}")
def write_output(path: Path, payload):
    path.write_text("return " + to_lua(payload) + "\n", encoding="utf-8")
def run_command(cwd: Path, command: str | None, command_args: list[str] | None, timeout_seconds: float | None):
    started = time.perf_counter()
    if command_args:
        args = list(command_args)
    elif command:
        args = shlex.split(command)
    else:
        raise ValueError("missing command")
    if not args:
        raise ValueError("empty command")
    try:
        completed = subprocess.run(
            args,
            shell=False,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
        duration_ms = int((time.perf_counter() - started) * 1000)
        output = (completed.stdout or "") + (completed.stderr or "")
        return {
            "exit_code": int(completed.returncode),
            "timed_out": False,
            "duration_ms": duration_ms,
            "output": output.strip(),
        }
    except subprocess.TimeoutExpired as exc:
        duration_ms = int((time.perf_counter() - started) * 1000)
        output = ((exc.stdout or "") + (exc.stderr or "")).strip()
        return {
            "exit_code": 124,
            "timed_out": True,
            "duration_ms": duration_ms,
            "output": output,
        }
def ignore_filter(_directory, names):
    ignored = set()
    for name in names:
        if name in IGNORE_NAMES:
            ignored.add(name)
        elif name.startswith(".coverage") or name.startswith(".luacov"):
            ignored.add(name)
    return ignored
def copy_project(source_root: Path, destination_root: Path):
    shutil.copytree(source_root, destination_root, ignore=ignore_filter, dirs_exist_ok=True)
def run_single_mutation(
    worker_root: Path,
    project_root: Path,
    target_file: str,
    command: str | None,
    command_args: list[str] | None,
    timeout_seconds: float,
    job: dict,
    verbose: bool,
    total: int,
):
    worker_root.mkdir(parents=True, exist_ok=True)
    temp_root = Path(tempfile.mkdtemp(prefix="mutate4lua-", dir=str(worker_root)))
    try:
        copy_project(project_root, temp_root)
        target_path = temp_root / target_file
        target_path.parent.mkdir(parents=True, exist_ok=True)
        target_path.write_text(job["mutated_source"], encoding="utf-8")
        if verbose:
            print(f"Worker starting {job['site_index']}/{total}: {job['description']}", flush=True)
        result = run_command(temp_root, command, command_args, timeout_seconds)
        if verbose:
            status = "KILLED" if result["timed_out"] or result["exit_code"] != 0 else "SURVIVED"
            print(f"Worker finished {job['site_index']}/{total}: {status}", flush=True)
        result.update({
            "site_index": job["site_index"],
            "line": job["line"],
            "description": job["description"],
        })
        return result
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)
def handle_run(config: dict, output: Path):
    result = run_command(
        Path(config["cwd"]),
        config.get("command"),
        config.get("command_args"),
        config.get("timeout_seconds"),
    )
    write_output(output, result)
def handle_mutate_batch(config: dict, output: Path):
    project_root = Path(config["project_root"])
    worker_root = project_root / ".mutate4lua" / "workers"
    worker_root.mkdir(parents=True, exist_ok=True)
    jobs = config.get("jobs", [])
    results = []
    max_workers = max(1, int(config.get("max_workers", 1)))
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [
            executor.submit(
                run_single_mutation,
                worker_root,
                project_root,
                config["target_file"],
                config.get("command"),
                config.get("command_args"),
                config.get("timeout_seconds") or 1,
                job,
                bool(config.get("verbose")),
                len(jobs),
            )
            for job in jobs
        ]
        for future in as_completed(futures):
            results.append(future.result())
    write_output(output, {"results": results})
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["run", "mutate-batch"])
    parser.add_argument("--config", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    output = Path(args.output)
    if args.mode == "run":
        handle_run(config, output)
    else:
        handle_mutate_batch(config, output)
if __name__ == "__main__":
    main()
