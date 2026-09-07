#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/update_macos.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/time-manager-macos-update-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

SOURCE_APP="$TEST_ROOT/build/时间块.app"
INSTALL_DIR="$TEST_ROOT/Applications"
mkdir -p "$SOURCE_APP/Contents/MacOS" "$INSTALL_DIR" "$TEST_ROOT/user-data"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$SOURCE_APP/Contents/Info.plist"
printf 'new-build\n' > "$SOURCE_APP/Contents/MacOS/version"

TARGET_APP="$INSTALL_DIR/时间块.app"
mkdir -p "$TARGET_APP/Contents/MacOS"
printf 'old-build\n' > "$TARGET_APP/Contents/MacOS/version"
printf 'keep-this-data\n' > "$TEST_ROOT/user-data/preferences.json"

bash "$SCRIPT_PATH" \
  --skip-build \
  --no-launch \
  --install-dir "$INSTALL_DIR" \
  --source-app "$SOURCE_APP"

[[ "$(<"$TARGET_APP/Contents/MacOS/version")" == "new-build" ]]
[[ "$(<"$TEST_ROOT/user-data/preferences.json")" == "keep-this-data" ]]
[[ -z "$(find "$INSTALL_DIR" -maxdepth 1 -name '.时间块.app.*' -print -quit)" ]]

printf 'macOS update script test passed\n'
