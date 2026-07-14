#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

if [[ -f "${SCRIPT_DIR}/.hydrojudge-install" ]]; then
  INSTALL_DIR="$SCRIPT_DIR"
else
  INSTALL_DIR="/opt/hydrojudge-docker"
fi
CONFIG_DIR="/etc/hydrojudge-docker"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="hydrojudge-autoscale.service"
KEEP_DATA=false
KEEP_IMAGE=false
PURGE_CONFIG=false
ASSUME_YES=false

log() {
  echo "[卸载] $*"
}

fail() {
  echo "[卸载] 错误：$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：sudo ./install.sh uninstall [选项]

也可以直接执行：sudo ./uninstall.sh [选项]

选项：
  --install-dir PATH   指定安装目录，默认自动识别
  --keep-data          保留 Docker 数据卷
  --keep-image         保留 hydrojudge-worker 镜像
  --purge              同时删除 /etc/hydrojudge-docker 中的账号配置和回滚副本
  -y, --yes            不询问确认
  -h, --help           显示帮助

默认会删除自动扩容服务、容器、数据卷、镜像和程序文件，
但保留 /etc/hydrojudge-docker 中的正式配置和上次成功配置。
EOF
}

ORIGINAL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -ge 2 ]] || fail "--install-dir 缺少路径"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --keep-data)
      KEEP_DATA=true
      shift
      ;;
    --keep-image)
      KEEP_IMAGE=true
      shift
      ;;
    --purge)
      PURGE_CONFIG=true
      shift
      ;;
    -y|--yes)
      ASSUME_YES=true
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
[[ -d "$INSTALL_DIR" ]] || fail "安装目录不存在，拒绝自动卸载：$INSTALL_DIR"
INSTALL_DIR="$(cd -- "$INSTALL_DIR" && pwd -P)"
[[ "$INSTALL_DIR" != "/" && "$INSTALL_DIR" != "/opt" && "$INSTALL_DIR" != "/usr" ]] \
  || fail "拒绝删除危险目录：$INSTALL_DIR"
[[ "$INSTALL_DIR" != *"/../"* && "$INSTALL_DIR" != */.. ]] \
  || fail "安装目录不能包含 .. 路径段"

[[ -f "${INSTALL_DIR}/.hydrojudge-install" ]] \
  || fail "没有找到有效的安装标记，拒绝自动卸载：$INSTALL_DIR"

if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || fail "需要 root 权限，且未找到 sudo"
  exec sudo -- "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
fi

if ! $ASSUME_YES; then
  [[ -t 0 || -t 1 ]] || fail "非交互环境请使用 --yes"
  DELETE_DATA_TEXT="是"
  DELETE_IMAGE_TEXT="是"
  DELETE_CONFIG_TEXT="否"
  $KEEP_DATA && DELETE_DATA_TEXT="否"
  $KEEP_IMAGE && DELETE_IMAGE_TEXT="否"
  $PURGE_CONFIG && DELETE_CONFIG_TEXT="是"
  echo "即将卸载 HydroJudge Docker 评测机："
  echo "  安装目录：$INSTALL_DIR"
  echo "  删除数据卷：$DELETE_DATA_TEXT"
  echo "  删除镜像：$DELETE_IMAGE_TEXT"
  echo "  删除账号配置：$DELETE_CONFIG_TEXT"
  read -r -p "确认继续？[y/N] " answer </dev/tty
  [[ "$answer" == "y" || "$answer" == "Y" ]] || exit 0
fi

command -v flock >/dev/null 2>&1 || fail "未找到命令：flock"
exec 9>"${INSTALL_DIR}/.update.lock"
flock -n 9 || fail "另一个安装、更新或卸载任务正在运行"

log "停止并删除自动扩容服务"
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

PROJECT_NAME="hydrojudge-docker"
IMAGE_NAME="hydrojudge-worker:local"
if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
  cd "$INSTALL_DIR"
  if docker compose version >/dev/null 2>&1; then
    compose_metadata="$(docker compose config --format json 2>/dev/null || true)"
    if [[ -n "$compose_metadata" ]] && command -v python3 >/dev/null 2>&1; then
      PROJECT_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("name", "hydrojudge-docker"))' <<<"$compose_metadata")"
      IMAGE_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["hydrojudge"].get("image", "hydrojudge-worker:local"))' <<<"$compose_metadata")"
    fi

    log "停止并删除评测容器"
    if $KEEP_DATA; then
      docker compose down --remove-orphans || true
      log "已保留数据卷；匿名卷可能需要手动重新挂载"
    else
      docker compose down --volumes --remove-orphans || true
    fi
  fi
fi

if ! $KEEP_DATA && command -v docker >/dev/null 2>&1; then
  log "清理项目残留数据卷"
  while IFS= read -r volume_name; do
    [[ -n "$volume_name" ]] && docker volume rm "$volume_name" >/dev/null 2>&1 || true
  done < <(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT_NAME}" 2>/dev/null || true)
fi

if ! $KEEP_IMAGE && command -v docker >/dev/null 2>&1; then
  log "删除镜像：$IMAGE_NAME"
  docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || log "镜像仍被其他容器使用，已跳过"
fi

if [[ -d "$INSTALL_DIR" ]]; then
  log "删除程序目录：$INSTALL_DIR"
  cd /
  rm -rf -- "$INSTALL_DIR"
fi

if $PURGE_CONFIG; then
  log "删除账号配置：$CONFIG_DIR"
  rm -rf -- "$CONFIG_DIR"
else
  log "保留账号配置及回滚副本：$CONFIG_DIR"
fi

log "卸载完成"
