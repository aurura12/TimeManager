#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="时间块.app"
APP_BUNDLE_ID="com.example.timeManager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="/Applications"
SOURCE_APP_PATH="$REPO_ROOT/build/macos/Build/Products/Release/$APP_NAME"
SKIP_TESTS=0
SKIP_BUILD=0
LAUNCH_APP=1
USE_SUDO=0

usage() {
  cat <<'EOF'
用法：
  scripts/update_macos.sh [选项]

默认行为：
  1. 获取依赖、运行分析和测试；
  2. 构建 macOS release；
  3. 原子替换 /Applications/时间块.app；
  4. 启动更新后的时间块。

选项：
  --skip-tests             跳过 flutter analyze 和 flutter test
  --skip-build             使用已有的 macOS .app，不重新构建
  --no-launch              更新后不启动时间块
  --install-dir DIR        覆盖安装目录，默认 /Applications
  --source-app PATH        指定待安装的 .app 路径
  -h, --help               显示帮助

说明：脚本只替换应用程序本体，不删除 ~/Library 下的应用数据、偏好设置或钥匙串内容。
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

log() {
  echo "[时间块] $*"
}

run_privileged() {
  if [[ "$USE_SUDO" -eq 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --no-launch)
      LAUNCH_APP=0
      shift
      ;;
    --install-dir)
      [[ "$#" -ge 2 ]] || die "--install-dir 需要一个路径"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --source-app)
      [[ "$#" -ge 2 ]] || die "--source-app 需要一个 .app 路径"
      SOURCE_APP_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知选项：$1（使用 --help 查看用法）"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "这个脚本只能在 macOS 上运行"

case "$INSTALL_DIR" in
  /*) ;;
  *) INSTALL_DIR="$REPO_ROOT/$INSTALL_DIR" ;;
esac

case "$SOURCE_APP_PATH" in
  /*) ;;
  *) SOURCE_APP_PATH="$REPO_ROOT/$SOURCE_APP_PATH" ;;
esac

TARGET_APP_PATH="$INSTALL_DIR/$APP_NAME"
[[ "$SOURCE_APP_PATH" != "$TARGET_APP_PATH" ]] || die "源应用不能与安装目标相同"

if [[ -e "$INSTALL_DIR" ]]; then
  [[ -w "$INSTALL_DIR" ]] || USE_SUDO=1
else
  INSTALL_PARENT="$(dirname "$INSTALL_DIR")"
  [[ -w "$INSTALL_PARENT" ]] || USE_SUDO=1
fi

if [[ "$USE_SUDO" -eq 1 ]]; then
  command -v sudo >/dev/null 2>&1 || die "安装目录不可写，且找不到 sudo"
  log "安装目录需要管理员权限，稍后可能会请求 macOS 密码"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  command -v flutter >/dev/null 2>&1 || die "找不到 flutter，请先配置 Flutter 环境"
  cd "$REPO_ROOT"

  log "获取 Flutter 依赖"
  flutter pub get

  if [[ "$SKIP_TESTS" -eq 0 ]]; then
    log "运行静态分析"
    flutter analyze
    log "运行完整测试"
    flutter test --reporter compact
  fi

  log "构建 macOS release"
  flutter build macos --release
fi

[[ -d "$SOURCE_APP_PATH" ]] || die "找不到待安装的应用：$SOURCE_APP_PATH"
[[ -f "$SOURCE_APP_PATH/Contents/Info.plist" ]] || die "源应用不是有效的 macOS .app：$SOURCE_APP_PATH"

run_privileged mkdir -p "$INSTALL_DIR"

STAGING_PATH="$INSTALL_DIR/.时间块.app.staging.$$.$RANDOM"
BACKUP_PATH="$INSTALL_DIR/.时间块.app.backup.$$.$RANDOM"
INSTALL_COMMITTED=0

cleanup() {
  local status=$?
  trap - EXIT

  if [[ "$INSTALL_COMMITTED" -eq 0 ]]; then
    if [[ -e "$TARGET_APP_PATH" && -e "$BACKUP_PATH" ]]; then
      run_privileged rm -rf "$TARGET_APP_PATH" || true
    fi
    if [[ ! -e "$TARGET_APP_PATH" && -e "$BACKUP_PATH" ]]; then
      run_privileged mv "$BACKUP_PATH" "$TARGET_APP_PATH" || true
    fi
  fi

  if [[ -e "$STAGING_PATH" ]]; then
    run_privileged rm -rf "$STAGING_PATH" || true
  fi

  exit "$status"
}
trap cleanup EXIT

log "准备更新：$TARGET_APP_PATH"
if pgrep -f "$TARGET_APP_PATH/Contents/MacOS/" >/dev/null 2>&1; then
  log "正在请求关闭当前运行的时间块"
  osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  WAIT_SECONDS=0
  while pgrep -f "$TARGET_APP_PATH/Contents/MacOS/" >/dev/null 2>&1; do
    [[ "$WAIT_SECONDS" -lt 30 ]] || die "时间块仍在运行，已取消更新以避免覆盖正在使用的文件"
    sleep 1
    WAIT_SECONDS=$((WAIT_SECONDS + 1))
  done
fi

log "复制新版本并执行原子替换"
run_privileged ditto "$SOURCE_APP_PATH" "$STAGING_PATH"

if [[ -e "$TARGET_APP_PATH" ]]; then
  run_privileged mv "$TARGET_APP_PATH" "$BACKUP_PATH"
fi

if ! run_privileged mv "$STAGING_PATH" "$TARGET_APP_PATH"; then
  die "新版本安装失败，正在恢复旧版本"
fi

INSTALL_COMMITTED=1
if [[ -e "$BACKUP_PATH" ]]; then
  if ! run_privileged rm -rf "$BACKUP_PATH"; then
    log "警告：新版本已安装，但旧版本临时备份未能清理：$BACKUP_PATH"
  fi
fi

log "更新完成：$TARGET_APP_PATH"
log "应用数据未被删除：~/Library 下的偏好设置、应用数据和钥匙串不会被脚本触碰"

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  open "$TARGET_APP_PATH"
fi
