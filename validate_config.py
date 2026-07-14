#!/usr/bin/env python3
"""校验 Docker Compose 渲染后的 HydroJudge 配置，且不输出敏感信息。"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from typing import Any
from urllib.parse import urlsplit


GOJUDGE_VERSION_RE = re.compile(r"v\d+\.\d+\.\d+(?:[+-][0-9A-Za-z.-]+)?")
HYDROJUDGE_VERSION_RE = re.compile(r"\d+\.\d+\.\d+(?:[+-][0-9A-Za-z.-]+)?")
SIZE_RE = re.compile(r"([1-9][0-9]*)([kmg])b?")
DURATION_RE = re.compile(r"(?:\d+(?:\.\d+)?(?:ns|us|ms|s|m|h))+")


class ConfigError(ValueError):
    """表示用户可修复的配置错误。"""


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{name} 缺失或格式错误")
    return value


def require_text(values: dict[str, Any], name: str) -> str:
    value = str(values.get(name, "")).strip()
    if not value:
        raise ConfigError(f"缺少必要配置：{name}")
    return value


def require_choice(values: dict[str, Any], name: str, choices: set[str]) -> str:
    value = require_text(values, name)
    if value not in choices:
        raise ConfigError(f"{name} 必须是 {'、'.join(sorted(choices))} 之一，当前值：{value}")
    return value


def require_bool(values: dict[str, Any], name: str) -> bool:
    value = require_text(values, name).lower()
    if value not in {"true", "false"}:
        raise ConfigError(f"{name} 必须是 true 或 false，当前值：{value}")
    return value == "true"


def require_int(values: dict[str, Any], name: str, minimum: int) -> int:
    raw = require_text(values, name)
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} 必须是整数，当前值：{raw}") from exc
    if value < minimum:
        raise ConfigError(f"{name} 必须大于等于 {minimum}，当前值：{value}")
    return value


def parse_size(values: dict[str, Any], name: str) -> int:
    raw = require_text(values, name)
    match = SIZE_RE.fullmatch(raw)
    if not match:
        raise ConfigError(f"{name} 必须使用正整数 k/m/g 大小，例如 256m 或 2g，当前值：{raw}")
    number = int(match.group(1))
    multiplier = {"k": 1024, "m": 1024**2, "g": 1024**3}[match.group(2).lower()]
    return number * multiplier


def require_duration(values: dict[str, Any], name: str) -> str:
    value = require_text(values, name)
    if not DURATION_RE.fullmatch(value) or not re.search(r"[1-9]", value):
        raise ConfigError(f"{name} 必须是正数时长，例如 30m、10s 或 1h30m，当前值：{value}")
    return value


def require_url(values: dict[str, Any], name: str) -> str:
    value = require_text(values, name)
    if any(character.isspace() for character in value):
        raise ConfigError(f"{name} 不能包含空白字符")
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ConfigError(f"{name} 必须是完整的 http:// 或 https:// 地址，当前值：{value}")
    try:
        parsed.port
    except ValueError as exc:
        raise ConfigError(f"{name} 使用了无效端口：{value}") from exc
    return value


def require_listen_address(values: dict[str, Any], name: str) -> str:
    value = require_text(values, name)
    try:
        parsed = urlsplit(f"//{value}")
        port = parsed.port
    except ValueError as exc:
        raise ConfigError(f"{name} 必须使用 host:port 格式，当前值：{value}") from exc
    if not parsed.hostname or port is None or not 1 <= port <= 65535:
        raise ConfigError(f"{name} 必须使用有效的 host:port 格式，当前值：{value}")
    return value


def require_positive_number(value: Any, name: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} 必须是正数，当前值：{value}") from exc
    if not math.isfinite(number) or number <= 0:
        raise ConfigError(f"{name} 必须是正数，当前值：{value}")
    return number


def require_positive_bytes(value: Any, name: str) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} 必须是正整数字节数，当前值：{value}") from exc
    if number <= 0:
        raise ConfigError(f"{name} 必须大于 0，当前值：{value}")
    return number


def validate_compose_config(document: dict[str, Any]) -> list[str]:
    """校验 Compose JSON，返回不阻止部署的中文警告。"""

    services = require_mapping(document.get("services"), "services")
    service = require_mapping(services.get("hydrojudge"), "services.hydrojudge")
    environment = require_mapping(service.get("environment"), "hydrojudge.environment")
    build = require_mapping(service.get("build"), "hydrojudge.build")
    build_args = require_mapping(build.get("args"), "hydrojudge.build.args")

    server_url = require_url(environment, "HYDRO_SERVER_URL")
    require_text(environment, "HYDRO_JUDGE_UNAME")
    password = require_text(environment, "HYDRO_JUDGE_PASSWORD")
    if password == "change_me":
        raise ConfigError("HYDRO_JUDGE_PASSWORD 仍为示例密码 change_me")
    if urlsplit(server_url).hostname in {"example.com", "oj.example.com"}:
        raise ConfigError("HYDRO_SERVER_URL 仍为示例站点，请填写真实 Hydro 地址")

    require_choice(environment, "HYDRO_HOST_TYPE", {"hydro", "vj4"})
    require_choice(environment, "HYDRO_DETAIL", {"case", "full", "none"})
    require_bool(environment, "HYDRO_STRICT_MEMORY")
    require_bool(environment, "HYDRO_PERFORMANCE")
    memory_max = parse_size(environment, "HYDRO_MEMORY_MAX")
    parse_size(environment, "HYDRO_STDIO_SIZE")
    parse_size(environment, "GOJUDGE_OUTPUT_LIMIT")
    parse_size(environment, "GOJUDGE_COPY_OUT_LIMIT")
    require_int(environment, "HYDRO_TESTCASES_MAX", 1)
    require_int(environment, "HYDRO_TOTAL_TIME_LIMIT", 1)
    require_int(environment, "HYDRO_PROCESS_LIMIT", 1)
    require_int(environment, "HYDRO_PARALLELISM", 1)
    concurrency = require_int(environment, "HYDRO_CONCURRENCY", 1)
    require_int(environment, "HYDRO_RERUN", 0)
    gojudge_parallelism = require_int(environment, "GOJUDGE_PARALLELISM", 1)
    require_url(environment, "HYDRO_SANDBOX_HOST")
    require_listen_address(environment, "GOJUDGE_HTTP_ADDR")
    require_duration(environment, "GOJUDGE_FILE_TIMEOUT")

    gojudge_version = require_text(build_args, "GOJUDGE_VERSION")
    hydrojudge_version = require_text(build_args, "HYDROJUDGE_VERSION")
    if not GOJUDGE_VERSION_RE.fullmatch(gojudge_version):
        raise ConfigError(f"GOJUDGE_VERSION 格式无效：{gojudge_version}")
    if not HYDROJUDGE_VERSION_RE.fullmatch(hydrojudge_version):
        raise ConfigError(f"HYDROJUDGE_VERSION 格式无效：{hydrojudge_version}")
    if "UBUNTU_MIRROR" in build_args:
        require_url(build_args, "UBUNTU_MIRROR")
    if "NPM_REGISTRY" in build_args:
        require_url(build_args, "NPM_REGISTRY")

    require_positive_number(service.get("cpus"), "CONTAINER_CPUS")
    memory_limit = require_positive_bytes(service.get("mem_limit"), "CONTAINER_MEMORY_LIMIT")
    swap_limit_raw = service.get("memswap_limit")
    if swap_limit_raw is not None:
        try:
            swap_limit = int(swap_limit_raw)
        except (TypeError, ValueError) as exc:
            raise ConfigError("CONTAINER_MEMORY_SWAP_LIMIT 格式无效") from exc
        if swap_limit != -1 and swap_limit < memory_limit:
            raise ConfigError("CONTAINER_MEMORY_SWAP_LIMIT 不能小于 CONTAINER_MEMORY_LIMIT")

    warnings: list[str] = []
    if concurrency > gojudge_parallelism:
        warnings.append(
            "HYDRO_CONCURRENCY 大于 GOJUDGE_PARALLELISM，任务会在沙箱前排队；通常建议两者一致"
        )
    if memory_max * concurrency > memory_limit:
        warnings.append(
            "HYDRO_MEMORY_MAX × HYDRO_CONCURRENCY 超过容器内存上限；高内存题并发时可能触发 OOM"
        )
    return warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="校验成功时不输出信息")
    args = parser.parse_args()

    try:
        document = json.load(sys.stdin)
        if not isinstance(document, dict):
            raise ConfigError("Compose 配置根节点必须是对象")
        warnings = validate_compose_config(document)
    except json.JSONDecodeError as exc:
        print(f"[配置校验] 错误：无法解析 Compose JSON：{exc}", file=sys.stderr)
        return 2
    except ConfigError as exc:
        print(f"[配置校验] 错误：{exc}", file=sys.stderr)
        return 2

    for warning in warnings:
        print(f"[配置校验] 警告：{warning}", file=sys.stderr)
    if not args.quiet:
        print("[配置校验] 通过：必填项、格式、版本号和资源限制均有效")
    return 0


if __name__ == "__main__":
    sys.exit(main())
