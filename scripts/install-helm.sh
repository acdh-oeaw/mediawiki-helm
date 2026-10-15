#!/usr/bin/env bash
set -euo pipefail
version=v3.17.3
archive="helm-${version}-linux-amd64.tar.gz"
task_tools="$(mktemp -d)"
trap 'rm -rf "$task_tools"' EXIT
curl -fsSL "https://get.helm.sh/$archive" -o "$task_tools/$archive"
curl -fsSL "https://get.helm.sh/$archive.sha256sum" -o "$task_tools/$archive.sha256sum"
(cd "$task_tools" && sha256sum -c "$archive.sha256sum")
tar --no-same-owner -xzf "$task_tools/$archive" -C "$task_tools"
mkdir -p "$PWD/.tools"
cp "$task_tools/linux-amd64/helm" "$PWD/.tools/helm"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$PWD/.tools" >> "$GITHUB_PATH"
fi
