#!/usr/bin/env python3
"""Safely scale HydroJudge Docker Compose workers up from host-side metrics."""

from __future__ import annotations

import argparse
import dataclasses
import fcntl
import json
import math
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent


def log(level: str, message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{timestamp} [autoscale] [{level}] {message}", flush=True)


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
        raise RuntimeError(f"command timed out: {' '.join(args)}") from exc
    if result.returncode:
        detail = result.stderr.strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}{suffix}")
    return result.stdout


def compose(*args: str, timeout: int = 30) -> str:
    return run_command(["docker", "compose", *args], timeout=timeout)


def parse_compose_environment(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def parse_bool(value: str, name: str) -> bool:
    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise ValueError(f"{name} must be true or false (got: {value})")


def parse_int(values: dict[str, str], name: str, default: int, minimum: int) -> int:
    raw = values.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer (got: {raw})") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum} (got: {value})")
    return value


def parse_float(
    values: dict[str, str], name: str, default: float, minimum: float, maximum: float
) -> float:
    raw = values.get(name, str(default))
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number (got: {raw})") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum} (got: {value})")
    return value


@dataclasses.dataclass(frozen=True)
class AutoscaleConfig:
    min_replicas: int
    max_replicas: int
    target_cpu_percent: float
    target_memory_percent: float
    scale_up_samples: int
    interval_seconds: int
    cooldown_seconds: int
    max_step: int
    enforce_host_capacity: bool
    host_headroom_percent: float
    dry_run: bool

    @classmethod
    def from_environment(cls, values: dict[str, str], force_dry_run: bool = False) -> "AutoscaleConfig":
        config = cls(
            min_replicas=parse_int(values, "AUTOSCALE_MIN_REPLICAS", 1, 1),
            max_replicas=parse_int(values, "AUTOSCALE_MAX_REPLICAS", 4, 1),
            target_cpu_percent=parse_float(
                values, "AUTOSCALE_TARGET_CPU_PERCENT", 70.0, 1.0, 100.0
            ),
            target_memory_percent=parse_float(
                values, "AUTOSCALE_TARGET_MEMORY_PERCENT", 70.0, 1.0, 100.0
            ),
            scale_up_samples=parse_int(values, "AUTOSCALE_SCALE_UP_SAMPLES", 2, 1),
            interval_seconds=parse_int(values, "AUTOSCALE_INTERVAL_SECONDS", 15, 1),
            cooldown_seconds=parse_int(values, "AUTOSCALE_COOLDOWN_SECONDS", 60, 0),
            max_step=parse_int(values, "AUTOSCALE_MAX_STEP", 1, 1),
            enforce_host_capacity=parse_bool(
                values.get("AUTOSCALE_ENFORCE_HOST_CAPACITY", "true"),
                "AUTOSCALE_ENFORCE_HOST_CAPACITY",
            ),
            host_headroom_percent=parse_float(
                values, "AUTOSCALE_HOST_HEADROOM_PERCENT", 10.0, 0.0, 90.0
            ),
            dry_run=force_dry_run
            or parse_bool(values.get("AUTOSCALE_DRY_RUN", "false"), "AUTOSCALE_DRY_RUN"),
        )
        if config.max_replicas < config.min_replicas:
            raise ValueError("AUTOSCALE_MAX_REPLICAS must be >= AUTOSCALE_MIN_REPLICAS")
        return config


@dataclasses.dataclass(frozen=True)
class ServiceCapacity:
    cpu_cores: float
    memory_bytes: int


@dataclasses.dataclass(frozen=True)
class HostCapacity:
    cpu_cores: int
    memory_bytes: int


@dataclasses.dataclass(frozen=True)
class ScaleDecision:
    average_cpu_percent: float
    average_memory_percent: float
    cpu_replicas: int
    memory_replicas: int
    uncapped_replicas: int
    desired_replicas: int


def calculate_effective_max(
    config: AutoscaleConfig, service: ServiceCapacity, host: HostCapacity
) -> int:
    if not config.enforce_host_capacity:
        return config.max_replicas

    usable_ratio = 1.0 - config.host_headroom_percent / 100.0
    capacity_limits = [config.max_replicas]
    if service.cpu_cores > 0 and host.cpu_cores > 0:
        capacity_limits.append(math.floor(host.cpu_cores * usable_ratio / service.cpu_cores))
    if service.memory_bytes > 0 and host.memory_bytes > 0:
        capacity_limits.append(math.floor(host.memory_bytes * usable_ratio / service.memory_bytes))
    return max(config.min_replicas, min(capacity_limits))


def calculate_desired_replicas(
    cpu_percentages: Iterable[float],
    memory_percentages: Iterable[float],
    service_cpu_cores: float,
    config: AutoscaleConfig,
    effective_max: int,
) -> ScaleDecision:
    cpu_values = list(cpu_percentages)
    memory_values = list(memory_percentages)
    if not cpu_values or len(cpu_values) != len(memory_values):
        raise ValueError("CPU and memory samples must contain the same non-zero number of workers")
    if service_cpu_cores <= 0:
        raise ValueError("service CPU limit must be greater than zero")

    cpu_capacity_percent = service_cpu_cores * 100.0
    cpu_equivalents = sum(value / cpu_capacity_percent for value in cpu_values)
    memory_equivalents = sum(value / 100.0 for value in memory_values)

    cpu_replicas = max(
        1, math.ceil(cpu_equivalents / (config.target_cpu_percent / 100.0) - 1e-9)
    )
    memory_replicas = max(
        1, math.ceil(memory_equivalents / (config.target_memory_percent / 100.0) - 1e-9)
    )
    uncapped = max(config.min_replicas, cpu_replicas, memory_replicas)
    desired = min(uncapped, effective_max)
    return ScaleDecision(
        average_cpu_percent=cpu_equivalents / len(cpu_values) * 100.0,
        average_memory_percent=sum(memory_values) / len(memory_values),
        cpu_replicas=cpu_replicas,
        memory_replicas=memory_replicas,
        uncapped_replicas=uncapped,
        desired_replicas=desired,
    )


def load_service_capacity() -> ServiceCapacity:
    rendered = json.loads(compose("config", "--format", "json"))
    service = rendered["services"]["hydrojudge"]
    cpu_cores = float(service.get("cpus") or 0)
    memory_bytes = int(service.get("mem_limit") or 0)
    if cpu_cores <= 0 or memory_bytes <= 0:
        raise ValueError("hydrojudge must define positive cpus and mem_limit values")
    return ServiceCapacity(cpu_cores=cpu_cores, memory_bytes=memory_bytes)


def load_host_capacity() -> HostCapacity:
    info = json.loads(run_command(["docker", "info", "--format", "{{json .}}"], timeout=30))
    return HostCapacity(cpu_cores=int(info["NCPU"]), memory_bytes=int(info["MemTotal"]))


def running_worker_ids() -> list[str]:
    return [
        line.strip()
        for line in compose("ps", "--status", "running", "-q", "hydrojudge").splitlines()
        if line.strip()
    ]


def parse_percentage(value: str) -> float:
    normalized = value.strip()
    if not normalized.endswith("%"):
        raise ValueError(f"invalid Docker percentage: {value}")
    return float(normalized[:-1])


def collect_metrics(container_ids: list[str]) -> tuple[list[float], list[float]]:
    output = run_command(
        [
            "docker",
            "stats",
            "--no-stream",
            "--format",
            "{{.CPUPerc}}\t{{.MemPerc}}",
            *container_ids,
        ],
        timeout=30,
    )
    cpu_values: list[float] = []
    memory_values: list[float] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise ValueError(f"unexpected docker stats output: {line}")
        cpu_values.append(parse_percentage(fields[0]))
        memory_values.append(parse_percentage(fields[1]))
    if len(cpu_values) != len(container_ids):
        raise RuntimeError(
            f"expected metrics for {len(container_ids)} workers, received {len(cpu_values)}"
        )
    return cpu_values, memory_values


def scale_to(replicas: int, dry_run: bool) -> None:
    if dry_run:
        log("DRY-RUN", f"would scale hydrojudge to {replicas} replicas")
        return
    compose(
        "up",
        "-d",
        "--no-recreate",
        "--scale",
        f"hydrojudge={replicas}",
        "hydrojudge",
        timeout=300,
    )


class Autoscaler:
    def __init__(
        self,
        config: AutoscaleConfig,
        service: ServiceCapacity,
        effective_max: int,
    ) -> None:
        self.config = config
        self.service = service
        self.effective_max = effective_max
        self.high_samples = 0
        self.last_scale_at = float("-inf")

    def sample(self) -> None:
        if (ROOT / ".autoscale.pause").exists():
            self.high_samples = 0
            log("INFO", "paused while a worker update is in progress")
            return

        container_ids = running_worker_ids()
        current = len(container_ids)
        if current < self.config.min_replicas:
            target = min(self.config.min_replicas, self.effective_max)
            log("WARN", f"only {current} workers are running; restoring minimum {target}")
            scale_to(target, self.config.dry_run)
            self.last_scale_at = time.monotonic()
            self.high_samples = 0
            return

        cpu_values, memory_values = collect_metrics(container_ids)
        decision = calculate_desired_replicas(
            cpu_values,
            memory_values,
            self.service.cpu_cores,
            self.config,
            self.effective_max,
        )
        capped = (
            f" raw={decision.uncapped_replicas} capacity-capped"
            if decision.uncapped_replicas > decision.desired_replicas
            else ""
        )
        log(
            "INFO",
            f"replicas={current} cpu={decision.average_cpu_percent:.1f}% "
            f"memory={decision.average_memory_percent:.1f}% "
            f"desired={decision.desired_replicas}/{self.effective_max}{capped}",
        )

        if decision.desired_replicas <= current:
            self.high_samples = 0
            return

        self.high_samples += 1
        if self.high_samples < self.config.scale_up_samples:
            log(
                "INFO",
                f"scale-up pressure sample {self.high_samples}/{self.config.scale_up_samples}",
            )
            return

        cooldown_remaining = self.config.cooldown_seconds - (time.monotonic() - self.last_scale_at)
        if cooldown_remaining > 0:
            log("INFO", f"scale-up cooldown active for another {math.ceil(cooldown_remaining)}s")
            return

        target = min(
            decision.desired_replicas,
            self.effective_max,
            current + self.config.max_step,
        )
        log("INFO", f"scaling hydrojudge from {current} to {target} replicas")
        scale_to(target, self.config.dry_run)
        self.last_scale_at = time.monotonic()
        self.high_samples = 0


def acquire_process_lock() -> object:
    lock_file = open(ROOT / ".autoscale.lock", "w", encoding="utf-8")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        lock_file.close()
        raise RuntimeError("another autoscale.py process is already running") from exc
    lock_file.write(f"{os.getpid()}\n")
    lock_file.flush()
    return lock_file


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="collect one sample and exit")
    parser.add_argument("--dry-run", action="store_true", help="log scaling actions without applying them")
    args = parser.parse_args()

    lock_file = None
    stop_event = threading.Event()
    try:
        compose("config", "--quiet")
        values = parse_compose_environment(compose("config", "--environment"))
        config = AutoscaleConfig.from_environment(values, force_dry_run=args.dry_run)
        service = load_service_capacity()
        host = load_host_capacity()
        effective_max = calculate_effective_max(config, service, host)
        lock_file = acquire_process_lock()

        signal.signal(signal.SIGINT, lambda _signum, _frame: stop_event.set())
        signal.signal(signal.SIGTERM, lambda _signum, _frame: stop_event.set())

        log(
            "INFO",
            f"starting scale-up-only autoscaler: min={config.min_replicas} "
            f"configured-max={config.max_replicas} effective-max={effective_max} "
            f"worker={service.cpu_cores:g}CPU/{service.memory_bytes / 1024**3:.1f}GiB "
            f"host={host.cpu_cores}CPU/{host.memory_bytes / 1024**3:.1f}GiB",
        )
        if effective_max < config.max_replicas:
            log(
                "WARN",
                "configured maximum was reduced by host capacity protection; lower per-worker "
                "limits or use a larger Docker host to permit more replicas",
            )
        usable_ratio = 1.0 - config.host_headroom_percent / 100.0
        if config.enforce_host_capacity and (
            service.cpu_cores * config.min_replicas > host.cpu_cores * usable_ratio
            or service.memory_bytes * config.min_replicas > host.memory_bytes * usable_ratio
        ):
            log(
                "WARN",
                "the configured minimum worker limits exceed protected host capacity; "
                "the minimum is kept, but its CPU or memory limit should be reduced",
            )

        autoscaler = Autoscaler(config, service, effective_max)
        while not stop_event.is_set():
            try:
                autoscaler.sample()
            except Exception as exc:  # Keep the monitor alive through transient Docker errors.
                autoscaler.high_samples = 0
                log("ERROR", str(exc))
                if args.once:
                    return 1
            if args.once:
                break
            stop_event.wait(config.interval_seconds)
        log("INFO", "stopped")
        return 0
    except (ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
        log("ERROR", str(exc))
        return 2
    finally:
        if lock_file is not None:
            lock_file.close()


if __name__ == "__main__":
    sys.exit(main())
