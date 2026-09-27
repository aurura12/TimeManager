#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Keep these defaults aligned with UpdateService and publish_android_release.sh.
GITEE_OWNER="${GITEE_OWNER:-zhou-jiaqi10}"
GITEE_REPO="${GITEE_REPO:-time_manager_releases}"
DEVICE_SERIAL=""
ADB_PATH=""
WORK_DIR=""

usage() {
  cat <<'EOF'
用法：
  scripts/install_latest_android.sh [选项]

从 Gitee 下载最新 Android APK，校验 SHA-256 后安装到通过 ADB 连接的设备。
默认使用唯一连接设备；多个设备时优先选唯一的实体设备，否则需指定序列号。
依赖 adb、curl、jq；脚本会尝试从 Android SDK 常见目录查找 adb。

选项：
  --device SERIAL  指定 adb devices 中的设备序列号
  --owner OWNER    覆盖 Gitee 用户名/组织名
  --repo REPO      覆盖 Gitee 发布仓库名
  -h, --help       显示帮助

环境变量：
  GITEE_TOKEN      可选；未设置时尝试读取 lib/config/diary_gitee_config.dart
  GITEE_OWNER      默认 zhou-jiaqi10
  GITEE_REPO       默认 time_manager_releases

安装使用 adb install -r，会覆盖应用程序并保留本机数据。
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

log() {
  echo "[时间块] $*"
}

GITEE_TOKEN="${GITEE_TOKEN:-}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --device)
      [[ "$#" -ge 2 ]] || die "--device 需要一个设备序列号"
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    --owner)
      [[ "$#" -ge 2 ]] || die "--owner 需要一个 Gitee 用户名或组织名"
      GITEE_OWNER="$2"
      shift 2
      ;;
    --repo)
      [[ "$#" -ge 2 ]] || die "--repo 需要一个 Gitee 仓库名"
      GITEE_REPO="$2"
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

[[ "$GITEE_OWNER" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Gitee owner 格式无效：$GITEE_OWNER"
[[ "$GITEE_REPO" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Gitee repo 格式无效：$GITEE_REPO"
GITEE_API_BASE="https://gitee.com/api/v5/repos/$GITEE_OWNER/$GITEE_REPO"

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "找不到 $1，请先安装或配置相关环境"
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

load_optional_gitee_token() {
  [[ -n "$GITEE_TOKEN" ]] && return
  local config_path="$REPO_ROOT/lib/config/diary_gitee_config.dart"
  [[ -f "$config_path" ]] || return

  GITEE_TOKEN="$(sed -nE \
    "s/.*static[[:space:]]+const[[:space:]]+String[[:space:]]+hardcodedToken[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/p" \
    "$config_path" | head -n 1)"
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
      die "指定设备未处于可用状态：$DEVICE_SERIAL"
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

curl_to_file() {
  local output_path="$1"
  local url="$2"
  local accept_header="$3"
  local -a curl_args=(
    --fail --silent --show-error --location --retry 2
    --connect-timeout 20 --max-time 600
    --header "Accept: $accept_header"
    --output "$output_path"
  )
  if [[ -n "$GITEE_TOKEN" ]]; then
    curl_args+=(--header "Authorization: token $GITEE_TOKEN")
  fi
  curl "${curl_args[@]}" "$url"
}

asset_url_for_name() {
  local asset_name="$1"
  jq -er --arg name "$asset_name" \
    '[.assets[]? | select(.name == $name) | (.url // .browser_download_url // empty)] | first // empty' \
    "$RELEASE_JSON"
}

abi_label() {
  case "$1" in
    arm64-v8a|armeabi-v7a|x86_64) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

require_command curl
require_command jq
ADB_PATH="$(find_adb 2>/dev/null || true)"
[[ -n "$ADB_PATH" ]] || die "找不到 adb；请安装 Android platform-tools，或设置 ANDROID_SDK_ROOT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/time_manager_install.XXXXXX")"
cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

select_device
DEVICE_ABIS="$("$ADB_PATH" -s "$DEVICE_SERIAL" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
if [[ -z "$DEVICE_ABIS" ]]; then
  DEVICE_ABIS="$("$ADB_PATH" -s "$DEVICE_SERIAL" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
fi
[[ -n "$DEVICE_ABIS" ]] || die "无法读取设备 CPU 架构：$DEVICE_SERIAL"

load_optional_gitee_token
RELEASE_JSON="$WORK_DIR/release.json"
log "正在查询 Gitee 最新 Android 版"
curl_to_file "$RELEASE_JSON" "$GITEE_API_BASE/releases/latest" "application/json" || \
  die "读取 Gitee 最新 Release 失败，请检查网络、仓库权限或 Gitee API 状态"

RELEASE_TAG="$(jq -er '.tag_name // empty' "$RELEASE_JSON")" || die "Release 响应中没有 tag_name"
[[ "$RELEASE_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || \
  die "最新 Release 版本号格式无效：$RELEASE_TAG"
RELEASE_VERSION="${RELEASE_TAG#v}"

declare -a APK_ASSET_NAMES=()
APK_ASSET_COUNT=0
while IFS= read -r asset_name; do
  [[ "$asset_name" =~ ^[A-Za-z0-9._-]+\.apk$ ]] || continue
  APK_ASSET_NAMES+=("$asset_name")
  APK_ASSET_COUNT=$((APK_ASSET_COUNT + 1))
done < <(jq -r '.assets[]? | .name // empty' "$RELEASE_JSON")
[[ "$APK_ASSET_COUNT" -gt 0 ]] || die "Release $RELEASE_TAG 中没有 APK 附件"

APK_NAME=""
IFS=',' read -r -a DEVICE_ABI_LIST <<< "$DEVICE_ABIS"
for device_abi in "${DEVICE_ABI_LIST[@]}"; do
  label="$(abi_label "$device_abi" || true)"
  [[ -n "$label" ]] || continue

  expected_name="time_manager-v${RELEASE_VERSION}-${label}.apk"
  for asset_name in "${APK_ASSET_NAMES[@]}"; do
    if [[ "$asset_name" == "$expected_name" ]]; then
      APK_NAME="$asset_name"
      break 2
    fi
  done

  MATCH_COUNT=0
  MATCHED_ASSET=""
  for asset_name in "${APK_ASSET_NAMES[@]}"; do
    if [[ "$asset_name" == *"-${label}.apk" || "$asset_name" == *"_${label}.apk" ]]; then
      MATCHED_ASSET="$asset_name"
      MATCH_COUNT=$((MATCH_COUNT + 1))
    fi
  done
  if [[ "$MATCH_COUNT" -eq 1 ]]; then
    APK_NAME="$MATCHED_ASSET"
    break
  elif [[ "$MATCH_COUNT" -gt 1 ]]; then
    die "Release $RELEASE_TAG 中有多个 $label APK，无法安全判断应安装哪个"
  fi
done

# A single APK with no architecture suffix is treated as a universal build.
if [[ -z "$APK_NAME" && "$APK_ASSET_COUNT" -eq 1 ]]; then
  APK_NAME="${APK_ASSET_NAMES[0]}"
fi
if [[ -z "$APK_NAME" ]]; then
  printf '设备支持的 ABI：%s\nRelease APK：%s\n' \
    "$DEVICE_ABIS" "${APK_ASSET_NAMES[*]}" >&2
  die "最新 Release 没有适配该设备架构的 APK"
fi

if ! APK_URL="$(asset_url_for_name "$APK_NAME")" || [[ "$APK_URL" != https://gitee.com/* ]]; then
  die "无法读取 APK 下载地址：$APK_NAME"
fi
CHECKSUM_NAME="$APK_NAME.sha256"
if ! CHECKSUM_URL="$(asset_url_for_name "$CHECKSUM_NAME")" || [[ "$CHECKSUM_URL" != https://gitee.com/* ]]; then
  die "Release $RELEASE_TAG 缺少有效的 SHA-256 附件：$CHECKSUM_NAME"
fi

APK_PATH="$WORK_DIR/$APK_NAME"
CHECKSUM_PATH="$WORK_DIR/$CHECKSUM_NAME"
log "下载 SHA-256 摘要：$CHECKSUM_NAME"
curl_to_file "$CHECKSUM_PATH" "$CHECKSUM_URL" "application/octet-stream" || die "下载 SHA-256 摘要失败"

line_count="$(awk 'NF { count++ } END { print count + 0 }' "$CHECKSUM_PATH")"
[[ "$line_count" == "1" ]] || die "SHA-256 文件格式无效"
read -r EXPECTED_SHA256 REPORTED_NAME EXTRA < "$CHECKSUM_PATH" || die "SHA-256 文件为空"
REPORTED_NAME="${REPORTED_NAME#\*}"
[[ -z "${EXTRA:-}" && "$REPORTED_NAME" == "$APK_NAME" ]] || \
  die "SHA-256 文件中的 APK 文件名不匹配"
[[ "${#EXPECTED_SHA256}" -eq 64 && "$EXPECTED_SHA256" =~ ^[A-Fa-f0-9]+$ ]] || \
  die "SHA-256 摘要格式无效"
EXPECTED_SHA256="$(printf '%s' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')"

log "下载 Android APK：$APK_NAME"
curl_to_file "$APK_PATH" "$APK_URL" "application/octet-stream" || die "下载 APK 失败"

if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "$APK_PATH" | awk '{ print tolower($1) }')"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum "$APK_PATH" | awk '{ print tolower($1) }')"
else
  die "找不到 shasum 或 sha256sum，无法校验 APK"
fi
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || die "APK SHA-256 校验失败，已停止安装"

log "校验通过，安装到设备 $DEVICE_SERIAL（设备 ABI：$DEVICE_ABIS）"
"$ADB_PATH" -s "$DEVICE_SERIAL" install -r "$APK_PATH"
log "安装完成：时间块 $RELEASE_VERSION"
