#!/usr/bin/env bash
set -euo pipefail

: "${HYDRO_SERVER_URL:?请设置 HYDRO_SERVER_URL，例如 https://oj.example.com/}"
: "${HYDRO_JUDGE_UNAME:?请设置 HYDRO_JUDGE_UNAME}"
: "${HYDRO_JUDGE_PASSWORD:?请设置 HYDRO_JUDGE_PASSWORD}"

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
  echo "[启动] 配置错误：$*" >&2
  exit 2
}

require_positive_integer() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail_config "$name 必须是正整数，当前值：$value"
}

require_nonnegative_integer() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^[0-9]+$ ]] || fail_config "$name 必须是非负整数，当前值：$value"
}

require_size() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^[1-9][0-9]*[kmg]b?$ ]] || fail_config "$name 必须使用正整数 k/m/g 大小，当前值：$value"
}

require_boolean() {
  local name="$1"
  local value="${!name}"
  [[ "$value" == "true" || "$value" == "false" ]] || fail_config "$name 必须是 true 或 false，当前值：$value"
}

require_duration() {
  local name="$1"
  local value="${!name}"
  [[ "$value" =~ ^([0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))+$ && "$value" =~ [1-9] ]] \
    || fail_config "$name 必须是正数时长，例如 30m、10s 或 1h30m，当前值：$value"
}

[[ "$HYDRO_HOST_TYPE" == "hydro" || "$HYDRO_HOST_TYPE" == "vj4" ]] \
  || fail_config "HYDRO_HOST_TYPE 必须是 hydro 或 vj4，当前值：$HYDRO_HOST_TYPE"
[[ "$HYDRO_DETAIL" == "full" || "$HYDRO_DETAIL" == "case" || "$HYDRO_DETAIL" == "none" ]] \
  || fail_config "HYDRO_DETAIL 必须是 full、case 或 none，当前值：$HYDRO_DETAIL"
[[ "$GOJUDGE_HTTP_ADDR" =~ ^[^[:space:]]+:[0-9]+$ ]] \
  || fail_config "GOJUDGE_HTTP_ADDR 必须使用 host:port 格式，当前值：$GOJUDGE_HTTP_ADDR"
[[ "$HYDRO_SERVER_URL" =~ ^https?://[^[:space:]]+$ ]] \
  || fail_config "HYDRO_SERVER_URL 必须是完整的 http:// 或 https:// 地址"
[[ "$HYDRO_SANDBOX_HOST" =~ ^https?://[^[:space:]]+$ ]] \
  || fail_config "HYDRO_SANDBOX_HOST 必须是完整的 http:// 或 https:// 地址"

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
require_duration GOJUDGE_FILE_TIMEOUT

json_quote_env() {
  python3.12 -c 'import json, os, sys; print(json.dumps(os.environ[sys.argv[1]]))' "$1"
}

# JSON strings are valid YAML scalars. This prevents special characters in URL,
# username or password from breaking the generated judge.yaml.
HYDRO_HOST_TYPE_YAML="$(json_quote_env HYDRO_HOST_TYPE)"
HYDRO_SERVER_URL_YAML="$(json_quote_env HYDRO_SERVER_URL)"
HYDRO_JUDGE_UNAME_YAML="$(json_quote_env HYDRO_JUDGE_UNAME)"
HYDRO_JUDGE_PASSWORD_YAML="$(json_quote_env HYDRO_JUDGE_PASSWORD)"
HYDRO_SANDBOX_HOST_YAML="$(json_quote_env HYDRO_SANDBOX_HOST)"
HYDRO_DETAIL_YAML="$(json_quote_env HYDRO_DETAIL)"
export HYDRO_HOST_TYPE_YAML HYDRO_SERVER_URL_YAML HYDRO_JUDGE_UNAME_YAML
export HYDRO_JUDGE_PASSWORD_YAML HYDRO_SANDBOX_HOST_YAML HYDRO_DETAIL_YAML

mkdir -p "$(dirname "$HYDRO_CONFIG_FILE")" /data/cache /data/tmp /root/.hydro

envsubst < /etc/hydro/judge.template.yaml > "$HYDRO_CONFIG_FILE"
chmod 600 "$HYDRO_CONFIG_FILE"

if ulimit -s unlimited; then
  echo "[启动] 栈大小限制：$(ulimit -s)"
else
  echo "[启动] 警告：无法把栈大小限制设置为 unlimited" >&2
  echo "[启动] 请检查 docker-compose.yml 中的 ulimits.stack 配置" >&2
fi

echo "[启动] 正在启动 go-judge：${GOJUDGE_HTTP_ADDR}"
/opt/go-judge \
  -http-addr "${GOJUDGE_HTTP_ADDR}" \
  -mount-conf /opt/mount.yaml \
  -parallelism "${GOJUDGE_PARALLELISM}" \
  -output-limit "${GOJUDGE_OUTPUT_LIMIT}" \
  -copy-out-limit "${GOJUDGE_COPY_OUT_LIMIT}" \
  -file-timeout "${GOJUDGE_FILE_TIMEOUT}" &

GOJUDGE_PID="$!"
HYDROJUDGE_PID=""

# 由 EXIT trap 间接调用。
# shellcheck disable=SC2329
cleanup() {
  trap - EXIT
  echo "[启动] 正在停止评测服务"
  if [[ -n "${HYDROJUDGE_PID}" ]]; then
    kill "${HYDROJUDGE_PID}" 2>/dev/null || true
  fi
  kill "${GOJUDGE_PID}" 2>/dev/null || true
  if [[ -n "${HYDROJUDGE_PID}" ]]; then
    wait "${HYDROJUDGE_PID}" 2>/dev/null || true
  fi
  wait "${GOJUDGE_PID}" 2>/dev/null || true
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
    echo "[启动] 错误：go-judge 在就绪前退出" >&2
    exit 1
  fi
  sleep 1
done

if [[ "${ready}" != "1" ]]; then
  echo "[启动] 错误：go-judge 未能在规定时间内就绪：${ready_url}" >&2
  exit 1
fi

echo "[启动] 正在使用 ${HYDRO_CONFIG_FILE} 启动 HydroJudge"
CONFIG_FILE="${HYDRO_CONFIG_FILE}" hydrojudge &

HYDROJUDGE_PID="$!"

if wait -n "${GOJUDGE_PID}" "${HYDROJUDGE_PID}"; then
  exit_code=0
else
  exit_code="$?"
fi

echo "[启动] 检测到子进程退出，容器将停止"
exit "$exit_code"
