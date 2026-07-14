#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CHECK_RUNTIME=true
FAILURES=0
WARNINGS=0
RENDERED_CONFIG=""
CONFIG_VALID=false

# 由 EXIT trap 间接调用。
# shellcheck disable=SC2329
cleanup() {
  [[ -n "$RENDERED_CONFIG" ]] && rm -f -- "$RENDERED_CONFIG"
}
trap cleanup EXIT

pass() {
  echo "[诊断] 通过：$*"
}

warn() {
  echo "[诊断] 警告：$*" >&2
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  echo "[诊断] 失败：$*" >&2
  FAILURES=$((FAILURES + 1))
}

usage() {
  cat <<'EOF'
HydroJudge Docker 中文环境诊断工具

用法：
  ./doctor.sh [--env-file FILE] [--skip-runtime]

选项：
  --env-file FILE   指定待检查的配置；默认使用项目目录中的 .env
  --skip-runtime    跳过 Docker 守护进程、容器和 systemd 运行状态检查
  -h, --help        显示帮助

该工具只读取配置和运行状态，不会构建镜像、重启服务或修改副本数，
也不会把账号、密码等配置内容输出到终端。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      [[ $# -ge 2 ]] || { fail "--env-file 缺少文件路径"; usage; exit 2; }
      ENV_FILE="$2"
      shift 2
      ;;
    --skip-runtime)
      CHECK_RUNTIME=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知选项：$1"
      usage
      exit 2
      ;;
  esac
done

echo "[诊断] 开始检查项目：$SCRIPT_DIR"

if [[ -f "$ENV_FILE" ]]; then
  ENV_FILE="$(cd -- "$(dirname -- "$ENV_FILE")" && pwd -P)/$(basename -- "$ENV_FILE")"
  pass "找到配置文件（内容不会显示）：$ENV_FILE"
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import os, stat, sys; raise SystemExit(0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode) & 0o077 == 0 else 1)' "$ENV_FILE"; then
      pass "配置文件权限未向组用户或其他用户开放"
    else
      warn "配置文件权限过宽；建议执行 chmod 600 '$ENV_FILE'"
    fi
  fi
else
  fail "未找到配置文件：$ENV_FILE；请先复制 .env.example 为 .env"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    pass "Python 版本满足 3.9+ 要求（$(python3 --version 2>&1)）"
  else
    fail "Python 版本低于 3.9（$(python3 --version 2>&1)）"
  fi
else
  fail "未找到 python3；请安装 Python 3.9 或更高版本"
fi

shell_scripts=(entrypoint.sh scale.sh doctor.sh install.sh update.sh uninstall.sh)
if command -v bash >/dev/null 2>&1; then
  shell_script_paths=()
  for script in "${shell_scripts[@]}"; do
    shell_script_paths+=("${SCRIPT_DIR}/${script}")
  done
  if bash -n "${shell_script_paths[@]}"; then
    pass "Shell 脚本语法正确"
  else
    fail "Shell 脚本存在语法错误"
  fi
else
  fail "未找到 bash"
fi

if command -v python3 >/dev/null 2>&1; then
  if PYTHONDONTWRITEBYTECODE=1 python3 -c '
import pathlib, sys
for name in sys.argv[1:]:
    source = pathlib.Path(name).read_text(encoding="utf-8")
    compile(source, name, "exec")
' "${SCRIPT_DIR}/autoscale.py" "${SCRIPT_DIR}/validate_config.py" "${SCRIPT_DIR}/wait_healthy.py"; then
    pass "Python 脚本语法正确"
  else
    fail "Python 脚本存在语法错误"
  fi

  if [[ -d "${SCRIPT_DIR}/tests" ]]; then
    if (cd "$SCRIPT_DIR" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -q); then
      pass "项目单元测试通过"
    else
      fail "项目单元测试失败"
    fi
  else
    warn "未找到 tests 目录，已跳过单元测试"
  fi
fi

if command -v docker >/dev/null 2>&1; then
  pass "已找到 Docker 客户端"
  if docker compose version >/dev/null 2>&1; then
    pass "Docker Compose 插件可用（$(docker compose version --short 2>/dev/null || docker compose version)）"
  else
    fail "Docker Compose 插件不可用；请安装 docker compose v2"
  fi
else
  fail "未找到 Docker；请先安装 Docker Engine 和 Compose 插件"
fi

if [[ -f "$ENV_FILE" ]] && command -v docker >/dev/null 2>&1 \
  && docker compose version >/dev/null 2>&1; then
  RENDERED_CONFIG="$(mktemp)"
  if docker compose --env-file "$ENV_FILE" -f "${SCRIPT_DIR}/docker-compose.yml" \
    config --format json >"$RENDERED_CONFIG"; then
    pass "Docker Compose 配置可以正常渲染"
    if command -v python3 >/dev/null 2>&1 \
      && python3 "${SCRIPT_DIR}/validate_config.py" <"$RENDERED_CONFIG"; then
      CONFIG_VALID=true
      pass "业务配置校验完成，未发现阻断问题"
    else
      fail "业务配置校验失败；请根据上方提示修改 .env"
    fi
  else
    fail "Docker Compose 配置渲染失败；请检查 .env 格式和必填项"
  fi
fi

if $CHECK_RUNTIME && command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    pass "Docker 守护进程运行正常"
    if $CONFIG_VALID && command -v python3 >/dev/null 2>&1; then
      capacity_output="$(
        python3 "${SCRIPT_DIR}/autoscale.py" --check-config --env-file "$ENV_FILE" 2>&1
      )"
      capacity_status=$?
      [[ -n "$capacity_output" ]] && printf '%s\n' "$capacity_output"
      if (( capacity_status == 0 )); then
        if [[ "$capacity_output" == *"[警告]"* ]]; then
          WARNINGS=$((WARNINGS + 1))
        fi
        pass "自动扩容参数与宿主机容量检查完成"
      else
        fail "自动扩容配置或宿主机容量读取失败"
      fi
    fi
    if [[ -f "$ENV_FILE" ]]; then
      container_ids=()
      while IFS= read -r container_id; do
        [[ -n "$container_id" ]] && container_ids+=("$container_id")
      done < <(docker compose --env-file "$ENV_FILE" -f "${SCRIPT_DIR}/docker-compose.yml" \
        ps -q hydrojudge 2>/dev/null)
      if (( ${#container_ids[@]} == 0 )); then
        warn "当前没有 HydroJudge 容器；首次安装前可忽略，已安装环境请检查 docker compose logs"
      else
        echo "[诊断] 容器状态："
        docker inspect --format \
          '{{.Name}}  运行={{.State.Status}}  健康={{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}}  重启={{.RestartCount}}' \
          "${container_ids[@]}" || fail "无法读取容器状态"
      fi
    fi
  else
    fail "Docker 守护进程未运行，或当前用户无权访问；请检查 systemctl status docker 和用户组权限"
  fi

  if [[ -f "${SCRIPT_DIR}/.hydrojudge-install" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet hydrojudge-autoscale.service; then
      pass "自动扩容服务正在运行"
    else
      warn "自动扩容服务未运行；如需自动扩容，请检查 systemctl status hydrojudge-autoscale.service"
    fi
  fi
elif ! $CHECK_RUNTIME; then
  warn "已按参数跳过运行状态检查"
fi

echo "[诊断] 检查结束：失败 ${FAILURES} 项，警告 ${WARNINGS} 项"
if (( FAILURES > 0 )); then
  echo "[诊断] 建议先修复失败项，再执行安装或更新。" >&2
  exit 1
fi
exit 0
