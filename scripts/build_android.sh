#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="时间块"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBSPEC="$REPO_ROOT/pubspec.yaml"

SKIP_TESTS=0
SKIP_BUMP=0
SKIP_GIT=0
NO_COPY=0
DRY_RUN=0
TARGET_PLATFORM="android-arm64"
DIST_DIR="$REPO_ROOT/dist"

BUMPED=0
VERSION_LINE=""
VERSION_STR=""
ORIG_VERSION_STR=""
VERSION_NAME=""
BUILD_NUMBER=""
NEW_VERSION_STR=""
NEW_VERSION_NAME=""

usage() {
  cat <<'EOF'
用法：
  scripts/build_android.sh [选项]

默认行为：
  1. 获取依赖、运行分析和测试；
  2. 自动把 pubspec.yaml 的版本号 +1（patch 和构建号都加，如 1.93.0+1 → 1.93.1+2）；
  3. 构建 Android arm64-v8a release APK；
  4. 把 APK 复制到 dist/ 目录（文件名带版本号）；
  5. 提交 pubspec.yaml 版本号变更并 push，让每次构建后工作区干净。

选项：
  --skip-tests             跳过 flutter analyze 和 flutter test
  --skip-bump              不自动递增版本号，用当前版本直接构建
  --no-git                 构建完成后不自动 git 提交和推送（默认会提交并 push）
  --no-copy                构建后不复制到 dist/，只保留默认输出路径
  --target-platform PLAT   目标架构：android-arm | android-arm64 | android-x64，默认 android-arm64
  --dist-dir DIR           覆盖 APK 输出目录，默认 <项目根>/dist
  --dry-run                只预览本次将要递增到的版本号，不修改任何文件、不构建
  -h, --help               显示帮助

说明：脚本只在构建失败或中断时回滚 pubspec.yaml 的版本号改动；成功后会只提交 pubspec.yaml 的版本号变更并 push 到当前分支的上游，不会把其他未提交改动一起带进这次提交。
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

log() {
  echo "[$APP_NAME] $*"
}

git_finish() {
  [[ "$SKIP_BUMP" -eq 1 ]] && return
  [[ "$SKIP_GIT" -eq 1 ]] && return

  cd "$REPO_ROOT"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log "警告：当前目录不是 git 仓库，跳过自动提交"
    return
  }

  git status --porcelain -- pubspec.yaml | grep -q . || {
    log "pubspec.yaml 没有变化，跳过自动提交"
    return
  }

  local other_changes
  other_changes="$(git status --porcelain | grep -v '^ M pubspec.yaml$' || true)"
  if [[ -n "$other_changes" ]]; then
    log "警告：检测到其他未提交改动，本次只提交 pubspec.yaml："
    echo "$other_changes" | sed 's/^/     /'
  fi

  log "提交版本号更新：$VERSION_STR"
  git commit -m "chore: bump version to $VERSION_STR" -- pubspec.yaml >/dev/null 2>&1 || {
    log "提交失败（可能没有可提交内容），跳过"
    return
  }

  if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    log "推送到远程上游分支"
    if ! git push; then
      log "警告：push 失败（网络或权限问题），本地已提交，可稍后手动执行 git push"
    fi
  else
    log "警告：当前分支没有上游分支，本地已提交但未推送"
  fi
  log "版本号已提交，工作区干净"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --skip-bump)
      SKIP_BUMP=1
      shift
      ;;
    --no-git)
      SKIP_GIT=1
      shift
      ;;
    --no-copy)
      NO_COPY=1
      shift
      ;;
    --target-platform)
      [[ "$#" -ge 2 ]] || die "--target-platform 需要一个平台参数"
      TARGET_PLATFORM="$2"
      shift 2
      ;;
    --dist-dir)
      [[ "$#" -ge 2 ]] || die "--dist-dir 需要一个路径"
      DIST_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

read_version() {
  local line
  line="$(grep -E '^version: ' "$PUBSPEC" || true)"
  [[ -n "$line" ]] || die "pubspec.yaml 中找不到 version 字段"
  VERSION_LINE="$line"
  VERSION_STR="${line#version: }"
  ORIG_VERSION_STR="$VERSION_STR"
  VERSION_NAME="${VERSION_STR%+*}"
  BUILD_NUMBER="${VERSION_STR##*+}"
  [[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法解析版本名：$VERSION_NAME"
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "无法解析构建号：$BUILD_NUMBER"
}

compute_next_version() {
  local major="${VERSION_NAME%%.*}"
  local rest="${VERSION_NAME#*.}" # minor.patch
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  NEW_VERSION_NAME="$major.$minor.$((patch + 1))"
  NEW_VERSION_STR="$NEW_VERSION_NAME+$((BUILD_NUMBER + 1))"
}

case "$TARGET_PLATFORM" in
  android-arm)   APK_FILE="app-armeabi-v7a-release.apk"; APK_LABEL="armeabi-v7a" ;;
  android-arm64) APK_FILE="app-arm64-v8a-release.apk";   APK_LABEL="arm64-v8a" ;;
  android-x64)   APK_FILE="app-x86_64-release.apk";      APK_LABEL="x86_64" ;;
  *) die "不支持的架构：$TARGET_PLATFORM（可选 android-arm / android-arm64 / android-x64）" ;;
esac

read_version
compute_next_version

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$SKIP_BUMP" -eq 1 ]]; then
    echo "当前版本：$VERSION_STR（--skip-bump，构建时不变）"
  else
    echo "当前版本：$VERSION_STR"
    echo "构建版本：$NEW_VERSION_STR"
  fi
  echo "目标架构：$TARGET_PLATFORM"
  echo "APK 输出：build/app/outputs/flutter-apk/$APK_FILE"
  exit 0
fi

if [[ "$SKIP_BUMP" -eq 0 ]]; then
  cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$status" -ne 0 && "$BUMPED" -eq 1 ]]; then
      log "构建失败或中断，正在回滚 pubspec.yaml 版本号到 $ORIG_VERSION_STR"
      sed -i '' "s|^version: .*|$VERSION_LINE|" "$PUBSPEC" 2>/dev/null || true
    fi
    exit "$status"
  }
  trap cleanup EXIT
fi

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

if [[ "$SKIP_BUMP" -eq 0 ]]; then
  log "版本号自增：$VERSION_STR → $NEW_VERSION_STR"
  sed -i '' "s|^version: .*|version: $NEW_VERSION_STR|" "$PUBSPEC"
  BUMPED=1
  VERSION_STR="$NEW_VERSION_STR"
  VERSION_NAME="$NEW_VERSION_NAME"
fi

log "构建 $TARGET_PLATFORM release APK（版本 $VERSION_STR）"
flutter build apk --release --target-platform "$TARGET_PLATFORM"

SOURCE_APK="$REPO_ROOT/build/app/outputs/flutter-apk/$APK_FILE"
[[ -f "$SOURCE_APK" ]] || die "构建完成但找不到 APK：$SOURCE_APK"

if [[ "$NO_COPY" -eq 0 ]]; then
  case "$DIST_DIR" in
    /*) ;;
    *) DIST_DIR="$REPO_ROOT/$DIST_DIR" ;;
  esac
  mkdir -p "$DIST_DIR"
  DIST_APK="$DIST_DIR/$APP_NAME-v$VERSION_NAME-$APK_LABEL.apk"
  cp "$SOURCE_APK" "$DIST_APK"
  log "构建完成：$DIST_APK"
else
  log "构建完成：$SOURCE_APK"
fi

git_finish
