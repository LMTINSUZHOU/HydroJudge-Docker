#!/usr/bin/env python3
"""等待指定数量的 HydroJudge Compose 容器全部进入 healthy 状态。"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent


@dataclass(frozen=True)
class WorkerState:
    name: str
    status: str
    health: str
    error: str = ""


def run_command(args: list[str], timeout: int = 30) -> str:
    try:
        result = subprocess.run(
            args,
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"命令执行超时：{' '.join(args)}") from exc
    if result.returncode:
        detail = result.stderr.strip().splitlines()
        suffix = f"：{detail[-1]}" if detail else ""
        raise RuntimeError(f"命令执行失败（退出码 {result.returncode}）：{' '.join(args)}{suffix}")
    return result.stdout


def compose(*args: str, timeout: int = 30) -> str:
    return run_command(["docker", "compose", *args], timeout=timeout)


def configured_replicas() -> int:
    environment: dict[str, str] = {}
    for line in compose("config", "--environment").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            environment[key] = value
    raw = environment.get("WORKER_REPLICAS", "1")
    try:
        replicas = int(raw)
    except ValueError as exc:
        raise ValueError(f"WORKER_REPLICAS 必须是非负整数，当前值：{raw}") from exc
    if replicas < 0:
        raise ValueError(f"WORKER_REPLICAS 必须是非负整数，当前值：{raw}")
    return replicas


def load_worker_states() -> list[WorkerState]:
    container_ids = [
        line.strip()
        for line in compose("ps", "--all", "-q", "hydrojudge").splitlines()
        if line.strip()
    ]
    if not container_ids:
        return []

    output = run_command(
        [
            "docker",
            "inspect",
            "--format",
            "{{json .Name}}\t{{json .State}}",
            *container_ids,
        ]
    )
    states: list[WorkerState] = []
    for line in output.splitlines():
        if not line.strip() or "\t" not in line:
            raise RuntimeError(f"无法识别 docker inspect 输出：{line}")
        raw_name, raw_state = line.split("\t", 1)
        name = str(json.loads(raw_name)).lstrip("/")
        state: dict[str, Any] = json.loads(raw_state)
        health_value = state.get("Health") or {}
        health = str(health_value.get("Status") or "missing")
        states.append(
            WorkerState(
                name=name,
                status=str(state.get("Status") or "unknown"),
                health=health,
                error=str(state.get("Error") or ""),
            )
        )
    return states


def evaluate_worker_states(
    states: Iterable[WorkerState], expected: int
) -> tuple[bool, bool, str]:
    """返回 (是否就绪, 是否不可恢复失败, 中文状态摘要)。"""

    workers = list(states)
    if len(workers) != expected:
        return False, False, f"容器数量 {len(workers)}/{expected}"
    if expected == 0:
        return True, False, "容器数量 0/0"

    terminal = [worker for worker in workers if worker.status in {"dead", "exited"}]
    if terminal:
        details = "；".join(
            f"{worker.name}={worker.status}{f'（{worker.error}）' if worker.error else ''}"
            for worker in terminal
        )
        return False, True, f"容器提前退出：{details}"

    unhealthy = [worker.name for worker in workers if worker.health == "unhealthy"]
    if unhealthy:
        return False, True, f"健康检查失败：{', '.join(unhealthy)}"

    ready = [worker for worker in workers if worker.status == "running" and worker.health == "healthy"]
    if len(ready) == expected:
        return True, False, f"健康副本 {len(ready)}/{expected}"

    summary = ", ".join(
        f"{worker.name}={worker.status}/{worker.health}" for worker in workers
    )
    return False, False, f"等待健康检查：{summary}"


def wait_for_workers(expected: int, timeout_seconds: int, interval_seconds: int) -> bool:
    deadline = time.monotonic() + timeout_seconds
    last_summary = ""
    while True:
        states = load_worker_states()
        ready, terminal, summary = evaluate_worker_states(states, expected)
        if summary != last_summary:
            print(f"[健康等待] {summary}", flush=True)
            last_summary = summary
        if ready:
            return True
        if terminal:
            return False
        if time.monotonic() >= deadline:
            print(f"[健康等待] 超过 {timeout_seconds} 秒仍未就绪", file=sys.stderr)
            return False
        time.sleep(interval_seconds)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replicas", type=int, help="期望副本数；默认读取 WORKER_REPLICAS")
    parser.add_argument("--timeout", type=int, default=150, help="最长等待秒数，默认 150")
    parser.add_argument("--interval", type=int, default=3, help="轮询间隔秒数，默认 3")
    args = parser.parse_args()

    try:
        replicas = configured_replicas() if args.replicas is None else args.replicas
        if replicas < 0:
            raise ValueError("--replicas 必须是非负整数")
        if args.timeout < 1 or args.interval < 1:
            raise ValueError("--timeout 和 --interval 必须是正整数")
        if wait_for_workers(replicas, args.timeout, args.interval):
            print(f"[健康等待] 成功：{replicas} 个 HydroJudge 副本已就绪")
            return 0
        print("[健康等待] 失败：请检查 docker compose ps 和 docker compose logs", file=sys.stderr)
        return 1
    except (RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"[健康等待] 错误：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
