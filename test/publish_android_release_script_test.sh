#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_ROOT/scripts/publish_android_release.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/time-manager-publish-notes-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
FAKE_APK="$TEST_ROOT/time_manager-v1.109.0-arm64-v8a.apk"
printf 'release-payload\n' > "$FAKE_APK"
NOTES_FILE="$TEST_ROOT/release-notes.md"

NOTES_TEXT='本次更新：

- 新增「背景图片」。
- 更新提示里现在会显示安装包大小。'
printf '%s\n' "$NOTES_TEXT" > "$NOTES_FILE"

make_releases_json() {
  jq -n --arg body "$1" \
    '[{"tag_name":"1.108.0","created_at":"2026-09-28T10:00:00+08:00","body":$body}]'
}

# 用假 curl 替代真实网络：按请求的 URL/方法返回 canned 响应。
# 发布脚本约定响应为 "<body>\n<http_code>"（curl --write-out 的形状）。
cat > "$FAKE_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

METHOD="GET"
URL=""
FORM_FILE=""
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in
    --request) METHOD="${ARGS[$((i + 1))]}" ;;
    --form) FORM_FILE="${ARGS[$((i + 1))]}" ;;
    http://*|https://*) URL="${ARGS[$i]}" ;;
  esac
done

BODY='{}'
CODE=200
case "$URL" in
  *"/releases?per_page=100")
    BODY="$RELEASES_JSON"
    ;;
  *"/releases/tags/"*)
    CODE=404
    BODY='{"message":"Not Found Release"}'
    ;;
  *"/releases")
    if [[ "$METHOD" == "POST" ]]; then
      BODY='{"id":999}'
    else
      BODY="$RELEASES_JSON"
    fi
    ;;
  *"/attach_files"*)
    if [[ "$METHOD" == "GET" ]]; then
      BODY='[]'
    else
      UPLOADED="$(basename "${FORM_FILE#file=@}")"
      BODY="$(jq -n --arg name "$UPLOADED" '{"name":$name}')"
    fi
    ;;
esac

printf '%s\n%s\n' "$BODY" "$CODE"
MOCK
chmod +x "$FAKE_BIN/curl"

run_publish() {
  GITEE_TOKEN=dummy-token \
  GITEE_OWNER=test-owner \
  GITEE_REPO=test-repo \
  PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_PATH" --skip-build --artifact "$FAKE_APK" --notes-file "$NOTES_FILE" "$@"
}

echo "=== 用例 1：说明与线上最新版本相同 → 拒绝发布 ==="
RELEASES_JSON="$(make_releases_json "$NOTES_TEXT")"
export RELEASES_JSON
if OUT="$(run_publish 2>&1)"; then
  echo '与线上说明完全相同时未拒绝发布' >&2
  exit 1
fi
grep -q "完全相同" <<<"$OUT"

echo "=== 用例 2：说明不同 → 查重通过并走完发布流程 ==="
export RELEASES_JSON="$(make_releases_json '本次更新：

- 另一个版本的不同说明。')"
OUT="$(run_publish 2>&1)"
grep -q "查重通过" <<<"$OUT"
grep -q "Android 发布完成" <<<"$OUT"

echo "=== 用例 3：--allow-stale-notes 绕过查重 ==="
export RELEASES_JSON="$(make_releases_json "$NOTES_TEXT")"
OUT="$(run_publish --allow-stale-notes 2>&1)"
grep -q "Android 发布完成" <<<"$OUT"

printf 'publish release notes guard test passed\n'
