#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法：
  scripts/generate_update_metadata.sh <安装包> [<安装包> ...]

说明：
  为每个 APK、EXE 或 DMG 生成同名的 .sha256 伴随文件。
  伴随文件格式为标准 sha256sum 单行：
    <64 位 SHA-256>  <安装包文件名>
  发布到 Gitee release 时，必须把安装包和对应的 .sha256 一起上传。
EOF
}

die() {
  echo "[错误] $*" >&2
  exit 1
}

[[ "$#" -gt 0 ]] || {
  usage >&2
  exit 2
}

if [[ "$#" -eq 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
  usage
  exit 0
fi

for artifact in "$@"; do
  [[ -f "$artifact" ]] || die "找不到安装包文件：$artifact"
  [[ ! -L "$artifact" ]] || die "安装包不能是符号链接：$artifact"

  artifact_name="$(basename "$artifact")"
  [[ "$artifact_name" =~ ^[A-Za-z0-9._-]+\.(apk|exe|dmg)$ ]] || \
    die "安装包文件名不符合发布契约：$artifact_name"

  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$artifact" | awk '{print tolower($1)}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$artifact" | awk '{print tolower($1)}')"
  else
    die "找不到 shasum 或 sha256sum，无法生成完整性摘要"
  fi

  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || \
    die "无法生成有效的 SHA-256：$artifact"

  metadata_path="$artifact.sha256"
  temporary_path="$metadata_path.tmp.$$"
  printf '%s  %s\n' "$digest" "$artifact_name" > "$temporary_path"
  mv -f "$temporary_path" "$metadata_path"
  echo "已生成 SHA-256：$metadata_path"
done
