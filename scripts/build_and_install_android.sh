#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="时间块"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE_SERIAL=""
ADB_PATH=""
TARGET_PLATFORM="android-arm64"
WORK_DIR=""

usage() {
  cat <<'EOF'
用法：
  scripts/build_and_install_android.sh [选项]

用当前代码构建 Android release APK，然后安装到通过 ADB 连接的设备。
不递增版本号、不 git 提交/推送（发布流程请用 scripts/build_android.sh）。
默认使用唯一连接设备；多个设备时优先选唯一的实体设备，否则需指定序列号。
依赖 adb；脚本会尝试从 Android SDK 常见目录查找 adb。Android 构建需要 JDK 17。

选项：
  --device SERIAL          指定 adb devices 中的设备序列号
  --target-platform PLAT   目标架构：android-arm | android-arm64 | android-x64，默认 android-arm64
  -h, --help               显示帮助

安装使用 adb install -r，会覆盖应用程序并保留本机数据。
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

log() {
  echo "[${APP_NAME}] $*"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --device)
      [[ "$#" -ge 2 ]] || die "--device 需要一个设备序列号"
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    --target-platform)
      [[ "$#" -ge 2 ]] || die "--target-platform 需要一个目标架构"
      TARGET_PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知选项：${1}（使用 --help 查看用法）"
      ;;
  esac
done

case "$TARGET_PLATFORM" in
  android-arm|android-arm64|android-x64) ;;
  *) die "不支持的目标架构：${TARGET_PLATFORM}（可选 android-arm / android-arm64 / android-x64）" ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "找不到 ${1}，请先安装或配置相关环境"
}

find_adb() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi

  local sdk_root candidate
  sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  for candidate in \
    "$sdk_root/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb" \
    "$HOME/Android/Sdk/platform-tools/adb"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

select_device() {
  local devices_file="$WORK_DIR/devices.txt"
  "$ADB_PATH" devices -l > "$devices_file"

  local -a connected=()
  local -a physical=()
  local connected_count=0
  local physical_count=0
  local serial state details
  while IFS=$'\t' read -r serial state details; do
    [[ "$state" == "device" ]] || continue
    connected+=("$serial")
    connected_count=$((connected_count + 1))
    if [[ "$serial" != emulator-* ]]; then
      physical+=("$serial")
      physical_count=$((physical_count + 1))
    fi
  done < <(awk 'NR > 1 && NF >= 2 { print $1 "\t" $2 "\t" $3 }' "$devices_file")

  if [[ -n "$DEVICE_SERIAL" ]]; then
    local found=0
    if [[ "$connected_count" -gt 0 ]]; then
      for serial in "${connected[@]}"; do
        [[ "$serial" == "$DEVICE_SERIAL" ]] && found=1
      done
    fi
    [[ "$found" -eq 1 ]] || {
      cat "$devices_file" >&2
      die "指定设备未处于可用状态：${DEVICE_SERIAL}"
    }
    return
  fi

  if [[ "$connected_count" -eq 1 ]]; then
    DEVICE_SERIAL="${connected[0]}"
    return
  fi
  if [[ "$physical_count" -eq 1 ]]; then
    DEVICE_SERIAL="${physical[0]}"
    return
  fi
  if [[ "$connected_count" -eq 0 ]]; then
    cat "$devices_file" >&2
    die "没有可用 Android 设备。请连接手机、开启 USB 调试，并在手机上允许这台 Mac 调试。"
  fi

  cat "$devices_file" >&2
  die "检测到多个设备，请用 --device <序列号> 指定安装目标"
}

require_command flutter
ADB_PATH="$(find_adb 2>/dev/null || true)"
[[ -n "$ADB_PATH" ]] || die "找不到 adb；请安装 Android platform-tools，或设置 ANDROID_SDK_ROOT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/time_manager_build_install.XXXXXX")"
cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

select_device

log "构建 release APK（${TARGET_PLATFORM}）"
cd "$REPO_ROOT"
flutter build apk --release --target-platform "$TARGET_PLATFORM"

APK_PATH="$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK_PATH" ]] || die "构建产物不存在：${APK_PATH}"

log "安装到设备 ${DEVICE_SERIAL}"
"$ADB_PATH" -s "$DEVICE_SERIAL" install -r "$APK_PATH"
log "安装完成：${APP_NAME}（$(grep -m1 '^version:' "$REPO_ROOT/pubspec.yaml" | awk '{ print $2 }')）"
