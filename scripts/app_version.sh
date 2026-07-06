#!/usr/bin/env bash
# 从 PDFLabCoreInfo.version(版本号唯一事实源)提取版本字符串并输出。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/PDFLabCore/Models.swift" | head -n 1
