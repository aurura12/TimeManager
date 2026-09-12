#!/usr/bin/env bash

set -euo pipefail

DEFAULT_EMULATOR="Pixel_7"
EMULATOR_NAME="${ANDROID_EMULATOR_NAME:-$DEFAULT_EMULATOR}"

# 允许用第一个非选项参数临时指定 AVD 名称；其余参数传给 flutter run。
if [[ $# -gt 0 && "$1" != -* ]]; then
  EMULATOR_NAME="$1"
  shift
fi

# 支持：./scripts/run_android.sh Pixel_7 -- --release
if [[ "${1:-}" == "--" ]]; then
  shift
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

if ! command -v flutter >/dev/null 2>&1; then
  echo "找不到 flutter，请先确认 Flutter 已加入 PATH。" >&2
  exit 1
fi

echo "正在启动 Android 模拟器：$EMULATOR_NAME"
flutter emulators --launch "$EMULATOR_NAME"

echo "等待模拟器被 Flutter 识别……"
ANDROID_DEVICE_ID=""

for ((attempt = 1; attempt <= 60; attempt++)); do
  ANDROID_DEVICE_ID="$(
    flutter devices 2>/dev/null || true
  )"
  ANDROID_DEVICE_ID="$(
    printf '%s\n' "$ANDROID_DEVICE_ID" | awk -F '•' '
      tolower($0) ~ /android/ {
        device_id = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", device_id)
        if (device_id != "") {
          print device_id
          exit
        }
      }
    '
  )"

  if [[ -n "$ANDROID_DEVICE_ID" ]]; then
    break
  fi

  sleep 2
done

if [[ -z "$ANDROID_DEVICE_ID" ]]; then
  echo "等待 Android 模拟器超时，请检查模拟器是否正常启动。" >&2
  echo "可以手动运行：flutter devices" >&2
  exit 1
fi

echo "已连接设备：$ANDROID_DEVICE_ID"
echo "正在运行 Flutter……"
flutter run -d "$ANDROID_DEVICE_ID" "$@"
