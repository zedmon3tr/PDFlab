#!/usr/bin/env bash
# 从 PDFLabCoreInfo.version(版本号唯一事实源)提取版本字符串并输出。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/PDFLabCore/Models.swift" | head -n 1)"
if [ -z "$VERSION" ]; then
    echo "app_version.sh: failed to extract version from Models.swift (regex did not match)" >&2
    exit 1
fi
echo "$VERSION"
