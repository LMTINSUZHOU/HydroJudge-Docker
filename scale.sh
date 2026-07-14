#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

docker compose config --quiet

CONFIGURED_REPLICAS="$(docker compose config --environment | awk -F= '$1 == "WORKER_REPLICAS" { print substr($0, index($0, "=") + 1); exit }')"
REPLICAS="${1:-${CONFIGURED_REPLICAS:-1}}"

if [[ ! "$REPLICAS" =~ ^[0-9]+$ ]]; then
  echo "[副本调整] 错误：副本数必须是非负整数，当前值：$REPLICAS" >&2
  exit 2
fi

MIN_REPLICAS="$(docker compose config --environment | awk -F= '$1 == "AUTOSCALE_MIN_REPLICAS" { print substr($0, index($0, "=") + 1); exit }')"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
if command -v systemctl >/dev/null 2>&1 \
  && systemctl is-active --quiet hydrojudge-autoscale.service 2>/dev/null \
  && [[ "$MIN_REPLICAS" =~ ^[1-9][0-9]*$ ]] \
  && (( REPLICAS < MIN_REPLICAS )); then
  echo "[副本调整] 警告：自动扩容服务会把副本数恢复到最小值 ${MIN_REPLICAS}" >&2
  echo "[副本调整] 如需保持较低副本数，请先停止自动扩容服务或修改 AUTOSCALE_MIN_REPLICAS" >&2
fi

echo "[副本调整] 目标 HydroJudge 副本数：${REPLICAS}"

docker compose up -d --scale hydrojudge="${REPLICAS}"
python3 ./wait_healthy.py --replicas "$REPLICAS"

echo "[副本调整] 当前容器："
docker compose ps hydrojudge
