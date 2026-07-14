#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

docker compose config --quiet

CONFIGURED_REPLICAS="$(docker compose config --environment | awk -F= '$1 == "WORKER_REPLICAS" { print substr($0, index($0, "=") + 1); exit }')"
RUNNING_REPLICAS="$(docker compose ps --status running -q hydrojudge | awk 'NF { count++ } END { print count + 0 }')"

if (( RUNNING_REPLICAS > 0 )); then
  REPLICAS="$RUNNING_REPLICAS"
else
  REPLICAS="${CONFIGURED_REPLICAS:-1}"
fi

if [[ ! "$REPLICAS" =~ ^[0-9]+$ ]]; then
  echo "[update] WORKER_REPLICAS must be a non-negative integer (got: $REPLICAS)" >&2
  exit 2
fi

PAUSE_FILE=".autoscale.pause"
touch "$PAUSE_FILE"
trap 'rm -f "$PAUSE_FILE"' EXIT

echo "[update] building configured judge versions..."
docker compose build --pull --no-cache hydrojudge

echo "[update] recreating hydrojudge containers, replicas=${REPLICAS}..."
docker compose up -d --force-recreate --scale hydrojudge="${REPLICAS}"

echo "[update] current containers:"
docker compose ps hydrojudge

echo "[update] recent logs:"
docker compose logs --tail 100 hydrojudge
