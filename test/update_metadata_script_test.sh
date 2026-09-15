#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_ROOT/scripts/generate_update_metadata.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/time-manager-update-metadata-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

ARTIFACT="$TEST_ROOT/time_manager_v1.96.0.apk"
printf 'release-payload\n' > "$ARTIFACT"

bash "$SCRIPT_PATH" "$ARTIFACT"

EXPECTED_DIGEST="$(shasum -a 256 "$ARTIFACT" | awk '{print tolower($1)}')"
EXPECTED_LINE="$EXPECTED_DIGEST  $(basename "$ARTIFACT")"
[[ "$(<"$ARTIFACT.sha256")" == "$EXPECTED_LINE" ]]

if bash "$SCRIPT_PATH" "$TEST_ROOT/not-a-release.bin" >/dev/null 2>&1; then
  echo 'metadata generator accepted an unsupported artifact' >&2
  exit 1
fi

INVALID_NAME="$TEST_ROOT/release package.apk"
printf 'release-payload\n' > "$INVALID_NAME"
if bash "$SCRIPT_PATH" "$INVALID_NAME" >/dev/null 2>&1; then
  echo 'metadata generator accepted an unsafe artifact name' >&2
  exit 1
fi

printf 'update metadata script test passed\n'
