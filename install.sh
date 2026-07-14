#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${PROJECT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

INSTALL_DIR="/opt/hydrojudge-docker"
CONFIG_DIR="/etc/hydrojudge-docker"
CONFIG_FILE="${CONFIG_DIR}/hydrojudge.env"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="hydrojudge-autoscale.service"
ENV_FILE=""
ENABLE_AUTOSCALE=true
BUILD_IMAGE=true
AUTOSCALER_WAS_ACTIVE=false

log() {
  echo "[install] $*"
}

fail() {
  echo "[install] error: $*" >&2
  if [[ "$AUTOSCALER_WAS_ACTIVE" == true ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  exit 1
}

usage() {
  cat <<'EOF'
HydroJudge Docker 统一管理脚本

用法：
  sudo ./install.sh install [安装选项]
  sudo ./install.sh uninstall [卸载选项]
  sudo ./install.sh update-version [更新选项]
  sudo ./install.sh update-config [更新选项]

命令：
  install          安装或覆盖安装评测机
  uninstall        卸载评测机，默认保留账号配置
  update-version   更新到最新 go-judge/HydroJudge 并重建镜像
  update-config    同步修改后的 .env 并应用到容器

安装选项：
  --install-dir PATH   安装目录，默认 /opt/hydrojudge-docker
  --env-file FILE      使用指定的 .env 配置文件
  --skip-build         不重建镜像，要求 hydrojudge-worker:local 已存在
  --no-autoscale       不安装或启用自动扩容 systemd 服务
  -h, --help           显示帮助

不带命令直接传入安装选项仍按 install 处理。
其他命令的详细选项可使用“sudo ./install.sh <命令> --help”查看。

重复执行安装脚本可覆盖升级程序文件。已有的
/etc/hydrojudge-docker/hydrojudge.env 默认会被保留。
EOF
}

COMMAND="install"
if [[ $# -gt 0 ]]; then
  case "$1" in
    install)
      shift
      ;;
    uninstall|update-version|update-config)
      COMMAND="$1"
      shift
      ;;
    help)
      usage
      exit 0
      ;;
    --*|-*)
      ;;
    *)
      fail "未知命令：$1；可用命令为 install、uninstall、update-version、update-config"
      ;;
  esac
fi

case "$COMMAND" in
  uninstall)
    [[ -x "${PROJECT_DIR}/uninstall.sh" ]] || fail "缺少卸载脚本：${PROJECT_DIR}/uninstall.sh"
    exec "${PROJECT_DIR}/uninstall.sh" "$@"
    ;;
  update-version|update-config)
    [[ -x "${PROJECT_DIR}/update.sh" ]] || fail "缺少更新脚本：${PROJECT_DIR}/update.sh"
    exec "${PROJECT_DIR}/update.sh" "$COMMAND" "$@"
    ;;
esac

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
    --skip-build)
      BUILD_IMAGE=false
      shift
      ;;
    --no-autoscale)
      ENABLE_AUTOSCALE=false
      shift
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

[[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] \
  || fail "安装目录必须是不含空格的安全绝对路径"
command -v python3 >/dev/null 2>&1 || fail "宿主机需要 Python 3.9 或更高版本"
INSTALL_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$INSTALL_DIR")"
[[ "$INSTALL_DIR" != "/" && "$INSTALL_DIR" != "/opt" && "$INSTALL_DIR" != "/usr" ]] \
  || fail "拒绝使用危险安装目录：$INSTALL_DIR"
[[ "$INSTALL_DIR" != *"/../"* && "$INSTALL_DIR" != */.. ]] \
  || fail "安装目录不能包含 .. 路径段"

if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || fail "需要 root 权限，且未找到 sudo"
  sudo_args=(--install-dir "$INSTALL_DIR")
  [[ -n "$ENV_FILE" ]] && sudo_args+=(--env-file "$ENV_FILE")
  $BUILD_IMAGE || sudo_args+=(--skip-build)
  $ENABLE_AUTOSCALE || sudo_args+=(--no-autoscale)
  exec sudo -- "$SCRIPT_PATH" "${sudo_args[@]}"
fi

[[ "$(uname -s)" == "Linux" ]] || fail "自动安装脚本仅支持 Linux"
[[ -d /run/systemd/system ]] || fail "未检测到正在运行的 systemd"

for command_name in docker flock python3 install sed systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "未找到命令：$command_name"
done
docker compose version >/dev/null 2>&1 || fail "未安装 Docker Compose 插件"
docker info >/dev/null 2>&1 || fail "Docker 服务未运行或当前用户无法访问 Docker"
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
  || fail "宿主机需要 Python 3.9 或更高版本"

required_files=(
  Dockerfile
  docker-compose.yml
  entrypoint.sh
  judge.template.yaml
  langs.yaml
  autoscale.py
  scale.sh
  update.sh
  uninstall.sh
  hydrojudge-autoscale.service
  .dockerignore
  .env.example
  README.md
  tests/test_autoscale.py
)
for filename in "${required_files[@]}"; do
  [[ -f "${PROJECT_DIR}/${filename}" ]] || fail "项目文件缺失：$filename"
done

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || fail "配置文件不存在：$ENV_FILE"
  SOURCE_ENV="$(cd -- "$(dirname -- "$ENV_FILE")" && pwd)/$(basename -- "$ENV_FILE")"
elif [[ -f "$CONFIG_FILE" ]]; then
  SOURCE_ENV="$CONFIG_FILE"
  log "保留已有配置：$CONFIG_FILE"
elif [[ -f "${PROJECT_DIR}/.env" ]]; then
  SOURCE_ENV="${PROJECT_DIR}/.env"
else
  fail "未找到 .env；请先复制 .env.example 并填写配置，或使用 --env-file"
fi

log "校验配置文件"
docker compose --env-file "$SOURCE_ENV" -f "${PROJECT_DIR}/docker-compose.yml" config --format json \
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

install -d -m 0755 "$INSTALL_DIR" "${INSTALL_DIR}/tests" "$CONFIG_DIR"
exec 9>"${INSTALL_DIR}/.update.lock"
flock -n 9 || fail "另一个安装、更新或卸载任务正在运行"

restore_autoscaler_on_error() {
  if $AUTOSCALER_WAS_ACTIVE; then
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}
trap restore_autoscaler_on_error ERR

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  AUTOSCALER_WAS_ACTIVE=true
  log "暂停已有自动扩容服务"
  systemctl stop "$SERVICE_NAME"
fi

log "安装程序文件到 $INSTALL_DIR"

INSTALLING_IN_PLACE=false
[[ "$PROJECT_DIR" -ef "$INSTALL_DIR" ]] && INSTALLING_IN_PLACE=true

readonly_files=(
  Dockerfile
  docker-compose.yml
  judge.template.yaml
  langs.yaml
  README.md
  .env.example
  hydrojudge-autoscale.service
  .dockerignore
)
executable_files=(
  entrypoint.sh
  autoscale.py
  scale.sh
  update.sh
  install.sh
  uninstall.sh
)

for filename in "${readonly_files[@]}"; do
  if $INSTALLING_IN_PLACE; then
    chmod 0644 "${INSTALL_DIR}/${filename}"
  else
    install -m 0644 "${PROJECT_DIR}/${filename}" "${INSTALL_DIR}/${filename}"
  fi
done
for filename in "${executable_files[@]}"; do
  if $INSTALLING_IN_PLACE; then
    chmod 0755 "${INSTALL_DIR}/${filename}"
  else
    install -m 0755 "${PROJECT_DIR}/${filename}" "${INSTALL_DIR}/${filename}"
  fi
done
if [[ -f "${PROJECT_DIR}/tests/test_autoscale.py" ]]; then
  if $INSTALLING_IN_PLACE; then
    chmod 0644 "${INSTALL_DIR}/tests/test_autoscale.py"
  else
    install -m 0644 "${PROJECT_DIR}/tests/test_autoscale.py" "${INSTALL_DIR}/tests/test_autoscale.py"
  fi
fi

SOURCE_ENV_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SOURCE_ENV")"
CONFIG_FILE_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CONFIG_FILE")"
if [[ "$SOURCE_ENV_REAL" != "$CONFIG_FILE_REAL" ]]; then
  install -m 0600 "$SOURCE_ENV" "$CONFIG_FILE"
else
  chmod 0600 "$CONFIG_FILE"
fi
rm -f "${INSTALL_DIR}/.env"
ln -s "$CONFIG_FILE" "${INSTALL_DIR}/.env"
touch "${INSTALL_DIR}/.hydrojudge-install"
chmod 0644 "${INSTALL_DIR}/.hydrojudge-install"
rm -f "${INSTALL_DIR}/.autoscale.lock" "${INSTALL_DIR}/.autoscale.pause"

cd "$INSTALL_DIR"
docker compose config --quiet
python3 -m unittest discover -s tests >/dev/null

if $BUILD_IMAGE; then
  log "构建评测机镜像"
  docker compose build --pull hydrojudge
else
  docker image inspect hydrojudge-worker:local >/dev/null 2>&1 \
    || fail "--skip-build 要求本机已经存在 hydrojudge-worker:local 镜像"
fi

log "启动评测容器"
./scale.sh

if $ENABLE_AUTOSCALE; then
  PYTHON_BIN="$(command -v python3)"
  UNIT_TEMP="$(mktemp)"
  trap 'rm -f "$UNIT_TEMP"' EXIT
  sed \
    -e "s|@INSTALL_DIR@|${INSTALL_DIR}|g" \
    -e "s|@PYTHON_BIN@|${PYTHON_BIN}|g" \
    "${INSTALL_DIR}/hydrojudge-autoscale.service" > "$UNIT_TEMP"
  install -m 0644 "$UNIT_TEMP" "${SYSTEMD_DIR}/${SERVICE_NAME}"
  rm -f "$UNIT_TEMP"
  trap - EXIT
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  log "自动扩容服务已启用：$SERVICE_NAME"
else
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}"
  systemctl daemon-reload
  log "已按要求跳过自动扩容服务"
fi

log "安装完成"
trap - ERR
docker compose ps hydrojudge
echo
echo "配置文件：$CONFIG_FILE"
echo "安装目录：$INSTALL_DIR"
if $ENABLE_AUTOSCALE; then
  echo "扩容日志：journalctl -u $SERVICE_NAME -f"
fi
echo "版本更新：sudo ${INSTALL_DIR}/install.sh update-version"
echo "配置更新：sudo ${INSTALL_DIR}/install.sh update-config"
echo "卸载命令：sudo ${INSTALL_DIR}/install.sh uninstall"
