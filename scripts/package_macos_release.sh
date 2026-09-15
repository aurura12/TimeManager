#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="时间块.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBSPEC="$REPO_ROOT/pubspec.yaml"
OUTPUT_DIR="$REPO_ROOT/dist"
SOURCE_APP_PATH="$REPO_ROOT/build/macos/Build/Products/Release/$APP_NAME"
SKIP_BUILD=0

usage() {
  cat <<'EOF'
用法：
  scripts/package_macos_release.sh [选项]

默认行为：
  1. 构建 macOS release .app；
  2. 打包为 dist/time_manager-v<版本>.dmg；
  3. 生成同名 .dmg.sha256 伴随文件。

选项：
  --skip-build       使用已有的 macOS .app，不重新构建
  --output-dir DIR   覆盖 DMG 输出目录，默认 <项目根>/dist
  --source-app PATH  指定待打包的 .app 路径
  -h, --help         显示帮助

发布约定：
  将 .dmg 和同名 .dmg.sha256 一起上传到 Gitee release。
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

log() {
  echo "[时间块] $*"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --output-dir)
      [[ "$#" -ge 2 ]] || die "--output-dir 需要一个路径"
      OUTPUT_DIR="$2"
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

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR" ;;
esac

case "$SOURCE_APP_PATH" in
  /*) ;;
  *) SOURCE_APP_PATH="$REPO_ROOT/$SOURCE_APP_PATH" ;;
esac

version_line="$(grep -E '^version: ' "$PUBSPEC" || true)"
[[ -n "$version_line" ]] || die "pubspec.yaml 中找不到 version 字段"
version_value="${version_line#version: }"
version_name="${version_value%%+*}"
[[ "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
  die "无法解析版本名：$version_name"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  command -v flutter >/dev/null 2>&1 || die "找不到 flutter，请先配置 Flutter 环境"
  cd "$REPO_ROOT"
  flutter build macos --release
fi

[[ -d "$SOURCE_APP_PATH" ]] || die "找不到待打包的应用：$SOURCE_APP_PATH"
[[ -f "$SOURCE_APP_PATH/Contents/Info.plist" ]] || \
  die "源应用不是有效的 macOS .app：$SOURCE_APP_PATH"
command -v hdiutil >/dev/null 2>&1 || die "找不到 hdiutil，无法生成 DMG"

mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/time_manager-v$version_name.dmg"
hdiutil create \
  -volname "时间块 $version_name" \
  -srcfolder "$SOURCE_APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

bash "$SCRIPT_DIR/generate_update_metadata.sh" "$DMG_PATH"
log "DMG 发布包已生成：$DMG_PATH"
