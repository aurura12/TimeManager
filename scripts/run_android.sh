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

# 模拟器进程可能仍在运行，但 ADB 尚未重新连上；这种情况下也不能再次启动同一个 AVD。
is_target_emulator_running() {
  local command_line
  while IFS= read -r command_line; do
    if [[ "$command_line" == *"-avd $EMULATOR_NAME"* || \
          "$command_line" == *"-avd=$EMULATOR_NAME"* ]]; then
      return 0
    fi
  done < <(ps -axo command= 2>/dev/null || true)

  return 1
}

# 如果 ADB 已经能识别目标 AVD，直接复用它；设备处于 booting/offline 时由上面的
# 进程检测负责兜底，避免把一个仍在启动的 AVD 当成不存在。
find_target_device_id() {
  [[ -n "$ADB_PATH" ]] || return 1

  local serial state avd_name
  while read -r serial state; do
    [[ "$serial" == emulator-* && "$state" == "device" ]] || continue

    avd_name="$(
      "$ADB_PATH" -s "$serial" emu avd name 2>/dev/null \
        | awk '{ gsub(/\r/, "", $0); if (NF && $0 !~ /^OK$/ && $0 !~ /^KO:/) { print; exit } }'
    )"
    if [[ "$avd_name" == "$EMULATOR_NAME" ]]; then
      echo "$serial"
      return 0
    fi
  done < <("$ADB_PATH" devices 2>/dev/null | awk 'NR > 1 { print $1, $2 }')

  return 1
}

ADB_PATH="$(find_adb 2>/dev/null || true)"
RUNNING_DEVICE_ID=""

if is_target_emulator_running; then
  RUNNING_DEVICE_ID="$(find_target_device_id || true)"
  if [[ -n "$RUNNING_DEVICE_ID" ]]; then
    echo "检测到已运行的 Android 模拟器：${EMULATOR_NAME}（${RUNNING_DEVICE_ID}），复用该实例。"
  else
    echo "检测到 Android 模拟器 $EMULATOR_NAME 已在运行，等待 ADB 重新连接……"
  fi
else
  RUNNING_DEVICE_ID="$(find_target_device_id || true)"
  if [[ -n "$RUNNING_DEVICE_ID" ]]; then
    echo "检测到已连接的 Android 模拟器：${EMULATOR_NAME}（${RUNNING_DEVICE_ID}），复用该实例。"
  else
    echo "正在启动 Android 模拟器：$EMULATOR_NAME"
    flutter emulators --launch "$EMULATOR_NAME"
  fi
fi

echo "等待模拟器被 Flutter 识别……"
ANDROID_DEVICE_ID=""

for ((attempt = 1; attempt <= 60; attempt++)); do
  FLUTTER_DEVICES_OUTPUT="$(flutter devices 2>/dev/null || true)"
  ANDROID_DEVICE_ID="$(
    printf '%s\n' "$FLUTTER_DEVICES_OUTPUT" | awk -F '•' -v expected="$EMULATOR_NAME" '
      tolower($0) ~ /android/ && NF >= 2 {
        device_id = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", device_id)
        device_name = $1
        if (device_id == expected || index(tolower(device_name), tolower(expected)) > 0) {
          print device_id
          found = 1
          exit
        }
        if (fallback == "" && device_id ~ /^emulator-/) {
          fallback = device_id
        }
      }
      END {
        if (!found && fallback != "") {
          print fallback
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
  echo "可以手动运行：flutter devices；如果模拟器窗口仍在但显示 offline，可重启 ADB：adb kill-server && adb start-server。" >&2
  exit 1
fi

echo "已连接设备：$ANDROID_DEVICE_ID"
echo "正在运行 Flutter……"
flutter run -d "$ANDROID_DEVICE_ID" "$@"
