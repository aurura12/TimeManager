#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="时间块"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBSPEC="$REPO_ROOT/pubspec.yaml"

# 与 lib/services/update_service.dart 保持一致。
GITEE_OWNER="${GITEE_OWNER:-zhou-jiaqi10}"
GITEE_REPO="${GITEE_REPO:-time_manager_releases}"
GITEE_API_BASE="https://gitee.com/api/v5/repos/$GITEE_OWNER/$GITEE_REPO"

TARGET_PLATFORM="android-arm64"
DIST_DIR="$REPO_ROOT/dist"
ARTIFACT_PATH=""
NOTES_FILE=""
SKIP_BUILD=0
# 发布前通常已经完成验证；需要再次检查时使用 --run-tests。
SKIP_TESTS=1
SKIP_BUMP=0
SKIP_GIT=0
DRY_RUN=0

API_STATUS=""
API_BODY=""
RELEASE_ASSETS_JSON="[]"
GITEE_TOKEN="${GITEE_TOKEN:-}"
GITEE_TOKEN_SOURCE=""

usage() {
  cat <<'EOF'
用法：
  GITEE_TOKEN=你的令牌 scripts/publish_android_release.sh [选项]

默认行为：
  1. 调用 build_android.sh：获取依赖、递增版本号并构建 Android arm64-v8a APK（次版本号 +1、patch 归零、构建号 +1）；
  2. 生成同名 .sha256 文件；
  3. 在 Gitee 的 time_manager_releases 仓库创建或复用 <版本> Release（标题为“时间块”）；
  4. 先上传 .sha256，再上传 APK，避免手机在发布过程中拿到缺少校验摘要的安装包。

  默认跳过 flutter analyze 和 flutter test；需要发布前再次检查时使用 --run-tests。

选项：
  --skip-build             使用 --artifact 指定的已有 APK，不重新构建
  --artifact PATH          指定已有 APK；传入后自动启用 --skip-build
  --run-tests              构建时执行 flutter analyze 和 flutter test
  --skip-tests             显式跳过 flutter analyze 和 flutter test（兼容旧用法）
  --skip-bump              构建时不递增 pubspec.yaml 版本号
  --no-git                 构建完成后不自动提交和推送版本号
  --target-platform PLAT   android-arm | android-arm64 | android-x64，默认 android-arm64
  --dist-dir DIR           构建产物目录，默认 <项目根>/dist
  --notes-file FILE        Release 说明文件，不传则使用默认说明
  --owner OWNER            覆盖 Gitee 用户名/组织名
  --repo REPO              覆盖 Gitee 发布仓库名
  --dry-run                只显示版本、文件和 Release 信息，不构建、不上传
  -h, --help               显示帮助

环境变量：
  GITEE_TOKEN              具有目标仓库 Release 写权限的 Gitee Token（可选）
                          未设置时自动读取 lib/config/diary_gitee_config.dart
  GITEE_OWNER              默认 zhou-jiaqi10
  GITEE_REPO               默认 time_manager_releases

示例：
  GITEE_TOKEN='...' scripts/publish_android_release.sh
  GITEE_TOKEN='...' scripts/publish_android_release.sh --no-git
  GITEE_TOKEN='...' scripts/publish_android_release.sh --run-tests
  GITEE_TOKEN='...' scripts/publish_android_release.sh --artifact dist/time_manager-v1.95.1-arm64-v8a.apk
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

log() {
  echo "[$APP_NAME] $*"
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
  esac
}

read_version() {
  local version_line version_value
  version_line="$(grep -E '^version: ' "$PUBSPEC" || true)"
  [[ -n "$version_line" ]] || die "pubspec.yaml 中找不到 version 字段"

  version_value="${version_line#version: }"
  VERSION_NAME="${version_value%%+*}"
  BUILD_NUMBER="${version_value##*+}"
  [[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "无法解析版本名：$VERSION_NAME"
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || \
    die "无法解析构建号：$BUILD_NUMBER"
  VERSION_STR="$version_value"
  RELEASE_TAG="v$VERSION_NAME"
}

compute_next_version() {
  local major minor rest
  major="${VERSION_NAME%%.*}"
  rest="${VERSION_NAME#*.}"
  minor="${rest%%.*}"
  NEXT_VERSION_NAME="$major.$((minor + 1)).0"
  NEXT_VERSION_STR="$NEXT_VERSION_NAME+$((BUILD_NUMBER + 1))"
}

artifact_label_for_platform() {
  case "$1" in
    android-arm) printf 'armeabi-v7a\n' ;;
    android-arm64) printf 'arm64-v8a\n' ;;
    android-x64) printf 'x86_64\n' ;;
    *) die "不支持的架构：${1}（可选 android-arm / android-arm64 / android-x64）" ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "找不到 $1，请先安装或配置相关环境"
}

load_gitee_token() {
  if [[ -n "$GITEE_TOKEN" ]]; then
    GITEE_TOKEN_SOURCE="GITEE_TOKEN 环境变量"
    return
  fi

  local config_path="$REPO_ROOT/lib/config/diary_gitee_config.dart"
  [[ -f "$config_path" ]] || die "未设置 GITEE_TOKEN，且找不到本地 Gitee 配置：$config_path"

  # 只读取现有本地配置中的 hardcodedToken，不把 Token 写入脚本或输出到终端。
  local configured_token
  configured_token="$(sed -nE \
    "s/.*static[[:space:]]+const[[:space:]]+String[[:space:]]+hardcodedToken[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" \
    "$config_path" | head -n 1)"
  [[ -n "$configured_token" ]] || \
    die "本地 Gitee 配置中没有可用的 hardcodedToken，请设置 GITEE_TOKEN"

  GITEE_TOKEN="$configured_token"
  GITEE_TOKEN_SOURCE="$config_path"
}

print_api_error() {
  local message
  message="$(printf '%s' "$API_BODY" | jq -r '.message // .error // empty' 2>/dev/null || true)"
  if [[ -n "$message" ]]; then
    echo "$message" >&2
  else
    printf '%s\n' "$API_BODY" >&2
  fi
}

require_api_success() {
  [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]] || {
    echo "Gitee API 请求失败（HTTP ${API_STATUS}）" >&2
    print_api_error
    exit 1
  }
}

# 将响应正文和 HTTP 状态码拆开，避免错误响应被 curl 的 stderr 截断。
api_call() {
  local method="$1"
  local url="$2"
  local response

  if ! response="$(curl \
    --silent \
    --show-error \
    --request "$method" \
    --header "Accept: application/json" \
    --header "Authorization: token $GITEE_TOKEN" \
    --write-out $'\n%{http_code}' \
    "$url" \
    "${@:3}")"; then
    die "无法连接 Gitee API：$url"
  fi

  API_STATUS="${response##*$'\n'}"
  API_BODY="${response%$'\n'*}"
}

extract_release_id() {
  printf '%s' "$API_BODY" | jq -r \
    --arg expected_tag "$RELEASE_TAG" \
    'if type == "object" then
       (.id // .release_id // .data?.id // empty)
     elif type == "array" then
       (map(select(.tag_name == $expected_tag))[0].id // empty)
     else
       empty
     end'
}

release_response_shape() {
  printf '%s' "$API_BODY" | jq -c \
    'if type == "object" then {type: type, keys: keys}
     elif type == "array" then {type: type, length: length}
     else {type: type}
     end' 2>/dev/null || printf '无法解析为 JSON'
}

create_release_or_get_id() {
  local release_url="$GITEE_API_BASE/releases/tags/$RELEASE_TAG"
  local release_id

  log "检查 Gitee Release：$RELEASE_TAG"
  api_call GET "$release_url"
  if [[ "$API_STATUS" == "200" ]]; then
    release_id="$(extract_release_id)"
    if [[ "$release_id" =~ ^[0-9]+$ ]]; then
      log "已找到现有 Release，准备复用：$RELEASE_TAG"
      RELEASE_ID="$release_id"
      return
    fi

    log "标签接口返回空结果，改从 Release 列表查找"
    api_call GET "$GITEE_API_BASE/releases?per_page=100"
    require_api_success
    release_id="$(extract_release_id)"
    if [[ "$release_id" =~ ^[0-9]+$ ]]; then
      log "已找到现有 Release，准备复用：$RELEASE_TAG"
      RELEASE_ID="$release_id"
      return
    fi
    log "Release 列表中没有 ${RELEASE_TAG}，准备创建"
  elif [[ "$API_STATUS" == "404" ]]; then
    log "未找到 ${RELEASE_TAG}，准备创建"
  else
    echo "读取 Gitee Release 失败（HTTP ${API_STATUS}）" >&2
    print_api_error
    exit 1
  fi

  local release_name="$APP_NAME"
  local release_body
  release_body=$'本次更新：\n\n- 修复日程同步问题：当日程内容没有变化时，不再重复上传或产生无意义的同步提交。\n- 远端有本地缺少的新内容时，仍会正常同步到本地；只有内容实际变化或清空日程时才会上传。'
  if [[ -n "$NOTES_FILE" ]]; then
    release_body="$(<"$NOTES_FILE")"
  fi

  log "创建 Gitee Release：$RELEASE_TAG"
  api_call POST "$GITEE_API_BASE/releases" \
    --data-urlencode "tag_name=$RELEASE_TAG" \
    --data-urlencode "name=$release_name" \
    --data-urlencode "body=$release_body" \
    --data-urlencode "prerelease=false"
  require_api_success

  release_id="$(extract_release_id)"
  [[ "$release_id" =~ ^[0-9]+$ ]] || \
    die "Gitee 创建 Release 成功，但响应中没有有效的 Release ID（返回结构：$(release_response_shape)）"
  RELEASE_ID="$release_id"
}

load_release_assets() {
  log "检查 Release 中已有的附件"
  api_call GET "$GITEE_API_BASE/releases/$RELEASE_ID/attach_files?per_page=100"
  require_api_success
  RELEASE_ASSETS_JSON="$API_BODY"
}

upload_asset_if_missing() {
  local release_id="$1"
  local artifact="$2"
  local asset_name
  asset_name="$(basename "$artifact")"

  if printf '%s' "$RELEASE_ASSETS_JSON" | jq -e \
    --arg expected_name "$asset_name" \
    'if type == "array" then any(.[]?; (.name // "") == $expected_name) else false end' \
    >/dev/null; then
    log "附件已存在，跳过上传：$asset_name"
    return
  fi

  upload_asset "$release_id" "$artifact"
}

upload_asset() {
  local release_id="$1"
  local artifact="$2"
  local asset_name
  asset_name="$(basename "$artifact")"

  log "上传附件：$asset_name"
  api_call POST "$GITEE_API_BASE/releases/$release_id/attach_files" \
    --form "file=@$artifact"
  require_api_success

  local uploaded_name
  uploaded_name="$(printf '%s' "$API_BODY" | jq -r '.name // empty')"
  [[ "$uploaded_name" == "$asset_name" ]] || \
    die "Gitee 返回的附件名异常：${uploaded_name}（预期：${asset_name}）"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --artifact)
      [[ "$#" -ge 2 ]] || die "--artifact 需要一个 APK 路径"
      ARTIFACT_PATH="$2"
      SKIP_BUILD=1
      shift 2
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --run-tests)
      SKIP_TESTS=0
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
    --notes-file)
      [[ "$#" -ge 2 ]] || die "--notes-file 需要一个文件路径"
      NOTES_FILE="$2"
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

[[ "$GITEE_OWNER" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Gitee owner 格式无效：$GITEE_OWNER"
[[ "$GITEE_REPO" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Gitee repo 格式无效：$GITEE_REPO"
GITEE_API_BASE="https://gitee.com/api/v5/repos/$GITEE_OWNER/$GITEE_REPO"

if [[ -n "$NOTES_FILE" ]]; then
  NOTES_FILE="$(resolve_path "$NOTES_FILE")"
  [[ -f "$NOTES_FILE" ]] || die "找不到 Release 说明文件：$NOTES_FILE"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  read_version
  compute_next_version
  artifact_label="$(artifact_label_for_platform "$TARGET_PLATFORM")"
  DIST_DIR="$(resolve_path "$DIST_DIR")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$SKIP_BUMP" -eq 1 ]]; then
      release_version="$VERSION_NAME"
      release_build="$VERSION_STR"
    else
      release_version="$NEXT_VERSION_NAME"
      release_build="$NEXT_VERSION_STR"
    fi
  else
    build_args=(--target-platform "$TARGET_PLATFORM" --dist-dir "$DIST_DIR")
    [[ "$SKIP_TESTS" -eq 1 ]] && build_args+=(--skip-tests)
    [[ "$SKIP_BUMP" -eq 1 ]] && build_args+=(--skip-bump)
    [[ "$SKIP_GIT" -eq 1 ]] && build_args+=(--no-git)

    log "开始执行 Android 发布构建"
    bash "$SCRIPT_DIR/build_android.sh" "${build_args[@]}"
    read_version
    release_version="$VERSION_NAME"
    release_build="$VERSION_STR"
    ARTIFACT_PATH="$DIST_DIR/time_manager-v$VERSION_NAME-$artifact_label.apk"
  fi
else
  read_version
  release_version="$VERSION_NAME"
  release_build="$VERSION_STR"
  if [[ -z "$ARTIFACT_PATH" ]]; then
    die "使用 --skip-build 时必须通过 --artifact 指定 APK"
  fi
  ARTIFACT_PATH="$(resolve_path "$ARTIFACT_PATH")"
fi

RELEASE_TAG="$release_version"

if [[ "$SKIP_BUMP" -eq 1 || "$SKIP_BUILD" -eq 1 ]]; then
  release_version="$VERSION_NAME"
  release_build="$VERSION_STR"
  RELEASE_TAG="$release_version"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -n "$ARTIFACT_PATH" ]]; then
    planned_artifact="$ARTIFACT_PATH"
  else
    planned_artifact="$DIST_DIR/time_manager-v$release_version-$(artifact_label_for_platform "$TARGET_PLATFORM").apk"
  fi
  echo "当前版本：$VERSION_STR"
  echo "发布版本：${release_build}（Release tag：${RELEASE_TAG}）"
  echo "APK：$planned_artifact"
  echo "校验文件：$planned_artifact.sha256"
  echo "Gitee：$GITEE_OWNER/$GITEE_REPO"
  exit 0
fi

require_command curl
require_command jq
load_gitee_token
[[ -f "$ARTIFACT_PATH" ]] || die "找不到 APK：$ARTIFACT_PATH"
[[ ! -L "$ARTIFACT_PATH" ]] || die "APK 不能是符号链接：$ARTIFACT_PATH"
[[ "$(basename "$ARTIFACT_PATH")" =~ ^[A-Za-z0-9._-]+\.apk$ ]] || \
  die "APK 文件名不符合发布契约：$(basename "$ARTIFACT_PATH")"

log "生成 APK SHA-256"
bash "$SCRIPT_DIR/generate_update_metadata.sh" "$ARTIFACT_PATH"
CHECKSUM_PATH="$ARTIFACT_PATH.sha256"

create_release_or_get_id
load_release_assets

# 先传校验文件，最后传 APK；这样客户端只有在校验文件已存在时才会看到 APK。
upload_asset_if_missing "$RELEASE_ID" "$CHECKSUM_PATH"
upload_asset_if_missing "$RELEASE_ID" "$ARTIFACT_PATH"

log "Android 发布完成"
log "Release：https://gitee.com/$GITEE_OWNER/$GITEE_REPO/releases/tag/$RELEASE_TAG"
log "版本：$release_build"
log "APK：$ARTIFACT_PATH"
