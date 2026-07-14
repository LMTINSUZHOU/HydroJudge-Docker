#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

docker compose config --quiet

CONFIGURED_REPLICAS="$(docker compose config --environment | awk -F= '$1 == "WORKER_REPLICAS" { print substr($0, index($0, "=") + 1); exit }')"
REPLICAS="${1:-${CONFIGURED_REPLICAS:-1}}"

if [[ ! "$REPLICAS" =~ ^[0-9]+$ ]]; then
  echo "[scale] replicas must be a non-negative integer (got: $REPLICAS)" >&2
  exit 2
fi

echo "[scale] target hydrojudge replicas: ${REPLICAS}"

docker compose up -d --scale hydrojudge="${REPLICAS}"

echo "[scale] current containers:"
docker compose ps hydrojudge
