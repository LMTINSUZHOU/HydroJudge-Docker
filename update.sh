#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SOURCE_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

if [[ -f "${SOURCE_DIR}/.hydrojudge-install" ]]; then
  INSTALL_DIR="$SOURCE_DIR"
else
  INSTALL_DIR="/opt/hydrojudge-docker"
fi

CONFIG_DIR="/etc/hydrojudge-docker"
CONFIG_FILE="${CONFIG_DIR}/hydrojudge.env"
SERVICE_NAME="hydrojudge-autoscale.service"
ACTION="update-version"
ENV_FILE=""
REQUESTED_GOJUDGE_VERSION=""
REQUESTED_HYDROJUDGE_VERSION=""
AUTOSCALER_WAS_ACTIVE=false
CANDIDATE_ENV=""
NEXT_ENV=""

log() {
  echo "[update] $*"
}

fail() {
  echo "[update] error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  sudo ./install.sh update-version [选项]
  sudo ./install.sh update-config [选项]

命令：
  update-version   查询最新稳定版本，重建镜像和评测容器
  update-config    读取默认 .env，并应用到容器和自动扩容器

通用选项：
  --install-dir PATH        安装目录，默认自动识别
  --env-file FILE           使用指定的 .env；默认读取 /etc/hydrojudge-docker/hydrojudge.env
  -h, --help                显示帮助

update-version 选项：
  --gojudge-version VERSION     手动指定 GOJUDGE_VERSION，作为联网失败时的回退
  --hydrojudge-version VERSION  手动指定 HYDROJUDGE_VERSION，作为联网失败时的回退

update-version 默认查询并安装两个组件的最新稳定版，然后无缓存重建镜像。
update-config 默认直接读取正式配置，不会重建镜像。
两个命令都会校验配置并避免自动缩减当前正在运行的副本数。
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    update-version|version)
      ACTION="update-version"
      shift
      ;;
    update-config|config)
      ACTION="update-config"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      ;;
    *)
      fail "未知更新命令：$1"
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -ge 2 ]] || fail "--install-dir 缺少路径"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --env-file)
      [[ $# -ge 2 ]] || fail "--env-file 缺少文件路径"
      ENV_FILE="$2"
      shift 2
      ;;
    --gojudge-version)
      [[ $# -ge 2 ]] || fail "--gojudge-version 缺少版本号"
      REQUESTED_GOJUDGE_VERSION="$2"
      shift 2
      ;;
    --hydrojudge-version)
      [[ $# -ge 2 ]] || fail "--hydrojudge-version 缺少版本号"
      REQUESTED_HYDROJUDGE_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知选项：$1"
      ;;
  esac
done

if [[ "$ACTION" == "update-config" ]] \
  && [[ -n "$REQUESTED_GOJUDGE_VERSION" || -n "$REQUESTED_HYDROJUDGE_VERSION" ]]; then
  fail "版本参数只能用于 update-version"
fi

if [[ -n "$REQUESTED_GOJUDGE_VERSION" ]] \
  && [[ ! "$REQUESTED_GOJUDGE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  fail "无效的 go-judge 版本：$REQUESTED_GOJUDGE_VERSION"
fi
if [[ -n "$REQUESTED_HYDROJUDGE_VERSION" ]] \
  && [[ ! "$REQUESTED_HYDROJUDGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  fail "无效的 HydroJudge 版本：$REQUESTED_HYDROJUDGE_VERSION"
fi

[[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] \
  || fail "安装目录必须是不含空格的安全绝对路径"
[[ -d "$INSTALL_DIR" ]] || fail "安装目录不存在：$INSTALL_DIR"
INSTALL_DIR="$(cd -- "$INSTALL_DIR" && pwd -P)"
[[ "$INSTALL_DIR" != "/" && "$INSTALL_DIR" != "/opt" && "$INSTALL_DIR" != "/usr" ]] \
  || fail "拒绝使用危险安装目录：$INSTALL_DIR"
[[ -f "${INSTALL_DIR}/.hydrojudge-install" ]] \
  || fail "安装目录缺少 .hydrojudge-install 标记：$INSTALL_DIR"
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] \
  || fail "安装目录缺少 docker-compose.yml：$INSTALL_DIR"

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || fail "配置文件不存在：$ENV_FILE"
  ENV_FILE="$(cd -- "$(dirname -- "$ENV_FILE")" && pwd -P)/$(basename -- "$ENV_FILE")"
fi

if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || fail "需要 root 权限，且未找到 sudo"
  sudo_args=("$ACTION" --install-dir "$INSTALL_DIR")
  [[ -n "$ENV_FILE" ]] && sudo_args+=(--env-file "$ENV_FILE")
  [[ -n "$REQUESTED_GOJUDGE_VERSION" ]] \
    && sudo_args+=(--gojudge-version "$REQUESTED_GOJUDGE_VERSION")
  [[ -n "$REQUESTED_HYDROJUDGE_VERSION" ]] \
    && sudo_args+=(--hydrojudge-version "$REQUESTED_HYDROJUDGE_VERSION")
  exec sudo -- "$SCRIPT_PATH" "${sudo_args[@]}"
fi

[[ "$(uname -s)" == "Linux" ]] || fail "更新脚本仅支持 Linux"
for command_name in awk docker flock install python3 systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "未找到命令：$command_name"
done
docker compose version >/dev/null 2>&1 || fail "未安装 Docker Compose 插件"
docker info >/dev/null 2>&1 || fail "Docker 服务未运行或当前用户无法访问 Docker"
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
  || fail "宿主机需要 Python 3.9 或更高版本"

exec 9>"${INSTALL_DIR}/.update.lock"
flock -n 9 || fail "另一个更新任务正在运行"

if [[ -n "$ENV_FILE" ]]; then
  SOURCE_ENV="$ENV_FILE"
elif [[ -f "$CONFIG_FILE" ]]; then
  SOURCE_ENV="$CONFIG_FILE"
  log "读取默认配置：$CONFIG_FILE"
else
  fail "未找到配置；请使用 --env-file 指定修改后的 .env"
fi

umask 077
install -d -m 0755 "$CONFIG_DIR"
CANDIDATE_ENV="$(mktemp "${CONFIG_DIR}/.hydrojudge.env.XXXXXX")"
NEXT_ENV="${CANDIDATE_ENV}.next"

cleanup() {
  rm -f -- "$CANDIDATE_ENV" "$NEXT_ENV" "${INSTALL_DIR}/.autoscale.pause"
  if $AUTOSCALER_WAS_ACTIVE; then
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

install -m 0600 "$SOURCE_ENV" "$CANDIDATE_ENV"

fetch_latest_versions() {
  python3 -c '
import json
import sys
import time
import urllib.request

sources = {
    "go-judge": "https://api.github.com/repos/criyle/go-judge/releases/latest",
    "HydroJudge": "https://registry.npmjs.org/@hydrooj%2Fhydrojudge/latest",
}

def fetch(url):
    last_error = None
    for attempt in range(3):
        try:
            request = urllib.request.Request(
                url,
                headers={
                    "Accept": "application/json",
                    "User-Agent": "HydroJudge-Docker-version-check",
                },
            )
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except Exception as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(attempt + 1)
    raise RuntimeError(str(last_error))

try:
    gojudge = fetch(sources["go-judge"])
    hydrojudge = fetch(sources["HydroJudge"])
    if gojudge.get("draft") or gojudge.get("prerelease"):
        raise RuntimeError("GitHub latest release is not stable")
    print("{}|{}".format(gojudge["tag_name"], hydrojudge["version"]))
except Exception as exc:
    print("无法获取最新评测机版本：{}".format(exc), file=sys.stderr)
    raise SystemExit(1)
'
}

if [[ "$ACTION" == "update-version" ]] \
  && [[ -z "$REQUESTED_GOJUDGE_VERSION" || -z "$REQUESTED_HYDROJUDGE_VERSION" ]]; then
  log "查询 go-judge 和 HydroJudge 最新稳定版"
  LATEST_VERSIONS="$(fetch_latest_versions)" \
    || fail "查询失败；可使用两个版本参数手动指定版本"
  IFS='|' read -r LATEST_GOJUDGE_VERSION LATEST_HYDROJUDGE_VERSION <<<"$LATEST_VERSIONS"
  REQUESTED_GOJUDGE_VERSION="${REQUESTED_GOJUDGE_VERSION:-$LATEST_GOJUDGE_VERSION}"
  REQUESTED_HYDROJUDGE_VERSION="${REQUESTED_HYDROJUDGE_VERSION:-$LATEST_HYDROJUDGE_VERSION}"
  log "目标版本：go-judge=${REQUESTED_GOJUDGE_VERSION}, HydroJudge=${REQUESTED_HYDROJUDGE_VERSION}"
fi

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 {
      if (!found) print key "=" value
      found = 1
      next
    }
    { print }
    END { if (!found) print key "=" value }
  ' "$file" > "$NEXT_ENV"
  chmod 0600 "$NEXT_ENV"
  mv -f -- "$NEXT_ENV" "$file"
}

[[ -n "$REQUESTED_GOJUDGE_VERSION" ]] \
  && set_env_value "GOJUDGE_VERSION" "$REQUESTED_GOJUDGE_VERSION" "$CANDIDATE_ENV"
[[ -n "$REQUESTED_HYDROJUDGE_VERSION" ]] \
  && set_env_value "HYDROJUDGE_VERSION" "$REQUESTED_HYDROJUDGE_VERSION" "$CANDIDATE_ENV"

validate_config() {
  local env_file="$1"
  docker compose --env-file "$env_file" -f "${INSTALL_DIR}/docker-compose.yml" config --format json \
    | python3 -c '
import json, re, sys
service = json.load(sys.stdin)["services"]["hydrojudge"]
env = service["environment"]
required = ("HYDRO_SERVER_URL", "HYDRO_JUDGE_UNAME", "HYDRO_JUDGE_PASSWORD")
missing = [name for name in required if not str(env.get(name, "")).strip()]
if missing:
    print("缺少必要配置：" + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
if env["HYDRO_JUDGE_PASSWORD"] == "change_me":
    print("HYDRO_JUDGE_PASSWORD 仍为示例密码 change_me", file=sys.stderr)
    raise SystemExit(1)
if "example.com" in env["HYDRO_SERVER_URL"]:
    print("HYDRO_SERVER_URL 仍为示例站点", file=sys.stderr)
    raise SystemExit(1)
build_args = service["build"]["args"]
if not re.fullmatch(r"v\d+\.\d+\.\d+(?:[+-][0-9A-Za-z.-]+)?", build_args["GOJUDGE_VERSION"]):
    print("GOJUDGE_VERSION 格式无效", file=sys.stderr)
    raise SystemExit(1)
if not re.fullmatch(r"\d+\.\d+\.\d+(?:[+-][0-9A-Za-z.-]+)?", build_args["HYDROJUDGE_VERSION"]):
    print("HYDROJUDGE_VERSION 格式无效", file=sys.stderr)
    raise SystemExit(1)
'
}

config_versions() {
  local env_file="$1"
  docker compose --env-file "$env_file" -f "${INSTALL_DIR}/docker-compose.yml" config --format json \
    | python3 -c '
import json, sys
build_args = json.load(sys.stdin)["services"]["hydrojudge"]["build"]["args"]
print("{}|{}".format(build_args["GOJUDGE_VERSION"], build_args["HYDROJUDGE_VERSION"]))
'
}

config_project_name() {
  local env_file="$1"
  docker compose --env-file "$env_file" -f "${INSTALL_DIR}/docker-compose.yml" config --format json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])'
}

log "校验候选配置"
validate_config "$CANDIDATE_ENV"
NEW_VERSIONS="$(config_versions "$CANDIDATE_ENV")"
NEW_PROJECT_NAME="$(config_project_name "$CANDIDATE_ENV")"
IFS='|' read -r GOJUDGE_VERSION HYDROJUDGE_VERSION <<<"$NEW_VERSIONS"
[[ "$GOJUDGE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] \
  || fail "配置中的 GOJUDGE_VERSION 无效：$GOJUDGE_VERSION"
[[ "$HYDROJUDGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] \
  || fail "配置中的 HYDROJUDGE_VERSION 无效：$HYDROJUDGE_VERSION"

if [[ -f "$CONFIG_FILE" ]]; then
  OLD_PROJECT_NAME="$(config_project_name "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PROJECT_NAME" && "$OLD_PROJECT_NAME" != "$NEW_PROJECT_NAME" ]]; then
    fail "不允许在更新时修改 COMPOSE_PROJECT_NAME（${OLD_PROJECT_NAME} -> ${NEW_PROJECT_NAME}）"
  fi
fi

if [[ "$ACTION" == "update-config" && -f "$CONFIG_FILE" ]]; then
  OLD_VERSIONS="$(config_versions "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_VERSIONS" && "$OLD_VERSIONS" != "$NEW_VERSIONS" ]]; then
    fail "检测到评测机版本发生变化；请改用 update-version"
  fi
fi

cd "$INSTALL_DIR"
RUNNING_IDS="$(docker compose ps --status running -q hydrojudge 2>/dev/null || true)"
RUNNING_REPLICAS="$(awk 'NF { count++ } END { print count + 0 }' <<<"$RUNNING_IDS")"
CONFIGURED_REPLICAS="$(
  docker compose --env-file "$CANDIDATE_ENV" -f docker-compose.yml config --environment \
    | awk -F= '$1 == "WORKER_REPLICAS" { print substr($0, index($0, "=") + 1); exit }'
)"
CONFIGURED_REPLICAS="${CONFIGURED_REPLICAS:-1}"
[[ "$CONFIGURED_REPLICAS" =~ ^[0-9]+$ ]] \
  || fail "WORKER_REPLICAS 必须是非负整数：$CONFIGURED_REPLICAS"

if (( RUNNING_REPLICAS > CONFIGURED_REPLICAS )); then
  REPLICAS="$RUNNING_REPLICAS"
else
  REPLICAS="$CONFIGURED_REPLICAS"
fi

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  AUTOSCALER_WAS_ACTIVE=true
fi
touch "${INSTALL_DIR}/.autoscale.pause"

log "保存配置到 $CONFIG_FILE"
install -m 0600 "$CANDIDATE_ENV" "$CONFIG_FILE"
rm -f "${INSTALL_DIR}/.env"
ln -s "$CONFIG_FILE" "${INSTALL_DIR}/.env"
docker compose config --quiet

if [[ "$ACTION" == "update-version" ]]; then
  log "重建评测机镜像：go-judge=${GOJUDGE_VERSION}, HydroJudge=${HYDROJUDGE_VERSION}"
  docker compose build --pull --no-cache hydrojudge
  log "使用新镜像重建评测容器，副本数=$REPLICAS"
  docker compose up -d --force-recreate --scale hydrojudge="$REPLICAS" hydrojudge
else
  log "应用新配置，副本数=$REPLICAS"
  docker compose up -d --scale hydrojudge="$REPLICAS" hydrojudge
fi

rm -f "${INSTALL_DIR}/.autoscale.pause"
if $AUTOSCALER_WAS_ACTIVE; then
  systemctl restart "$SERVICE_NAME"
  AUTOSCALER_WAS_ACTIVE=false
fi

rm -f -- "$CANDIDATE_ENV" "$NEXT_ENV"
trap - EXIT

log "更新完成"
docker compose ps hydrojudge
echo
echo "配置文件：$CONFIG_FILE"
echo "评测机版本：go-judge=${GOJUDGE_VERSION}, HydroJudge=${HYDROJUDGE_VERSION}"
