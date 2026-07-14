#!/usr/bin/env bash
set -euo pipefail

: "${HYDRO_SERVER_URL:?Please set HYDRO_SERVER_URL, for example https://oj.example.com/}"
: "${HYDRO_JUDGE_UNAME:?Please set HYDRO_JUDGE_UNAME}"
: "${HYDRO_JUDGE_PASSWORD:?Please set HYDRO_JUDGE_PASSWORD}"

# Hydro expects the server URL in judge.yaml to end with a slash.
if [[ "${HYDRO_SERVER_URL}" != */ ]]; then
  export HYDRO_SERVER_URL="${HYDRO_SERVER_URL}/"
fi

export HYDRO_HOST_TYPE="${HYDRO_HOST_TYPE:-hydro}"
export HYDRO_CONFIG_FILE="${HYDRO_CONFIG_FILE:-/root/.hydro/judge.yaml}"
export HYDRO_SANDBOX_HOST="${HYDRO_SANDBOX_HOST:-http://127.0.0.1:5050}"

export HYDRO_MEMORY_MAX="${HYDRO_MEMORY_MAX:-2048m}"
export HYDRO_STDIO_SIZE="${HYDRO_STDIO_SIZE:-256m}"
export HYDRO_STRICT_MEMORY="${HYDRO_STRICT_MEMORY:-false}"
export HYDRO_TESTCASES_MAX="${HYDRO_TESTCASES_MAX:-450}"
export HYDRO_TOTAL_TIME_LIMIT="${HYDRO_TOTAL_TIME_LIMIT:-3000}"
export HYDRO_PROCESS_LIMIT="${HYDRO_PROCESS_LIMIT:-32}"
export HYDRO_PARALLELISM="${HYDRO_PARALLELISM:-3}"
export HYDRO_CONCURRENCY="${HYDRO_CONCURRENCY:-3}"
export HYDRO_DETAIL="${HYDRO_DETAIL:-full}"
export HYDRO_RERUN="${HYDRO_RERUN:-1}"
export HYDRO_PERFORMANCE="${HYDRO_PERFORMANCE:-true}"

export GOJUDGE_HTTP_ADDR="${GOJUDGE_HTTP_ADDR:-127.0.0.1:5050}"
export GOJUDGE_PARALLELISM="${GOJUDGE_PARALLELISM:-3}"
export GOJUDGE_OUTPUT_LIMIT="${GOJUDGE_OUTPUT_LIMIT:-256m}"
export GOJUDGE_COPY_OUT_LIMIT="${GOJUDGE_COPY_OUT_LIMIT:-256m}"
export GOJUDGE_FILE_TIMEOUT="${GOJUDGE_FILE_TIMEOUT:-30m}"

fail_config() {
  echo "[entrypoint] invalid configuration: $*" >&2
  exit 2
}

require_positive_integer() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail_config "$name must be a positive integer (got: $value)"
}

require_nonnegative_integer() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^[0-9]+$ ]] || fail_config "$name must be a non-negative integer (got: $value)"
}

require_size() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^[1-9][0-9]*[kmg]b?$ ]] || fail_config "$name must use a positive k/m/g size (got: $value)"
}

require_boolean() {
  local name="$1"
  local value="${!name}"
  [[ "$value" == "true" || "$value" == "false" ]] || fail_config "$name must be true or false (got: $value)"
}

[[ "$HYDRO_HOST_TYPE" == "hydro" || "$HYDRO_HOST_TYPE" == "vj4" ]] \
  || fail_config "HYDRO_HOST_TYPE must be hydro or vj4 (got: $HYDRO_HOST_TYPE)"
[[ "$HYDRO_DETAIL" == "full" || "$HYDRO_DETAIL" == "case" || "$HYDRO_DETAIL" == "none" ]] \
  || fail_config "HYDRO_DETAIL must be full, case, or none (got: $HYDRO_DETAIL)"
[[ "$GOJUDGE_HTTP_ADDR" =~ ^[^[:space:]]+:[0-9]+$ ]] \
  || fail_config "GOJUDGE_HTTP_ADDR must be host:port (got: $GOJUDGE_HTTP_ADDR)"

require_size HYDRO_MEMORY_MAX
require_size HYDRO_STDIO_SIZE
require_size GOJUDGE_OUTPUT_LIMIT
require_size GOJUDGE_COPY_OUT_LIMIT
require_boolean HYDRO_STRICT_MEMORY
require_boolean HYDRO_PERFORMANCE
require_positive_integer HYDRO_TESTCASES_MAX
require_positive_integer HYDRO_TOTAL_TIME_LIMIT
require_positive_integer HYDRO_PROCESS_LIMIT
require_positive_integer HYDRO_PARALLELISM
require_positive_integer HYDRO_CONCURRENCY
require_positive_integer GOJUDGE_PARALLELISM
require_nonnegative_integer HYDRO_RERUN

json_quote_env() {
  python3.12 -c 'import json, os, sys; print(json.dumps(os.environ[sys.argv[1]]))' "$1"
}

# JSON strings are valid YAML scalars. This prevents special characters in URL,
# username or password from breaking the generated judge.yaml.
export HYDRO_HOST_TYPE_YAML="$(json_quote_env HYDRO_HOST_TYPE)"
export HYDRO_SERVER_URL_YAML="$(json_quote_env HYDRO_SERVER_URL)"
export HYDRO_JUDGE_UNAME_YAML="$(json_quote_env HYDRO_JUDGE_UNAME)"
export HYDRO_JUDGE_PASSWORD_YAML="$(json_quote_env HYDRO_JUDGE_PASSWORD)"
export HYDRO_SANDBOX_HOST_YAML="$(json_quote_env HYDRO_SANDBOX_HOST)"
export HYDRO_DETAIL_YAML="$(json_quote_env HYDRO_DETAIL)"

mkdir -p "$(dirname "$HYDRO_CONFIG_FILE")" /data/cache /data/tmp /root/.hydro

envsubst < /etc/hydro/judge.template.yaml > "$HYDRO_CONFIG_FILE"
chmod 600 "$HYDRO_CONFIG_FILE"

if ulimit -s unlimited; then
  echo "[entrypoint] stack size limit: $(ulimit -s)"
else
  echo "[entrypoint] warning: failed to set stack size limit to unlimited" >&2
  echo "[entrypoint] check docker-compose.yml ulimits.stack soft/hard settings" >&2
fi

echo "[entrypoint] starting go-judge on ${GOJUDGE_HTTP_ADDR}"
/opt/go-judge \
  -http-addr "${GOJUDGE_HTTP_ADDR}" \
  -mount-conf /opt/mount.yaml \
  -parallelism "${GOJUDGE_PARALLELISM}" \
  -output-limit "${GOJUDGE_OUTPUT_LIMIT}" \
  -copy-out-limit "${GOJUDGE_COPY_OUT_LIMIT}" \
  -file-timeout "${GOJUDGE_FILE_TIMEOUT}" &

GOJUDGE_PID="$!"
HYDROJUDGE_PID=""

cleanup() {
  trap - EXIT
  echo "[entrypoint] stopping services"
  kill "${GOJUDGE_PID}" 2>/dev/null || true
  if [[ -n "${HYDROJUDGE_PID}" ]]; then
    kill "${HYDROJUDGE_PID}" 2>/dev/null || true
  fi
  wait "${GOJUDGE_PID}" 2>/dev/null || true
  if [[ -n "${HYDROJUDGE_PID}" ]]; then
    wait "${HYDROJUDGE_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ready=0
ready_url="http://${GOJUDGE_HTTP_ADDR}/version"

for _ in $(seq 1 30); do
  if curl -fsS --max-time 1 "$ready_url" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${GOJUDGE_PID}" 2>/dev/null; then
    echo "[entrypoint] go-judge exited before it became ready"
    exit 1
  fi
  sleep 1
done

if [[ "${ready}" != "1" ]]; then
  echo "[entrypoint] go-judge did not become ready at ${ready_url}"
  exit 1
fi

echo "[entrypoint] starting hydrojudge with ${HYDRO_CONFIG_FILE}"
CONFIG_FILE="${HYDRO_CONFIG_FILE}" hydrojudge &

HYDROJUDGE_PID="$!"

if wait -n "${GOJUDGE_PID}" "${HYDROJUDGE_PID}"; then
  exit_code=0
else
  exit_code="$?"
fi

echo "[entrypoint] one process exited, shutting down"
exit "$exit_code"
