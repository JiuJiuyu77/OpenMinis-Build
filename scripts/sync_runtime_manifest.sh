#!/usr/bin/env bash
#
# 同步上游运行时清单
# 用法: ./scripts/sync_runtime_manifest.sh [--check-only]
#

set -euo pipefail

UPSTREAM_MANIFEST="https://raw.githubusercontent.com/OpenMinis/MinisApp-Runtime/main/Runtime/runtime-manifest.json"
LOCAL_MANIFEST="runtime-manifest.json"
CHECK_SCRIPT="scripts/check_runtime_manifest.py"

check_only=false
if [[ "${1:-}" == "--check-only" ]]; then
    check_only=true
fi

echo "==> 拉取上游运行时清单"
curl -fsSL "$UPSTREAM_MANIFEST" -o "$LOCAL_MANIFEST.new"

echo "==> 验证清单格式"
if ! python3 "$CHECK_SCRIPT" --manifest "$LOCAL_MANIFEST.new"; then
    echo "::error::上游清单验证失败"
    rm -f "$LOCAL_MANIFEST.new"
    exit 1
fi

if [ "$check_only" = true ]; then
    echo "==> 仅检查模式: 清单有效"
    rm -f "$LOCAL_MANIFEST.new"
    exit 0
fi

# 对比差异
if [ -f "$LOCAL_MANIFEST" ]; then
    echo "==> 对比差异"
    if diff -u "$LOCAL_MANIFEST" "$LOCAL_MANIFEST.new" || true; then
        echo "没有变化"
        rm -f "$LOCAL_MANIFEST.new"
        exit 0
    fi
fi

echo "==> 更新本地清单"
mv "$LOCAL_MANIFEST.new" "$LOCAL_MANIFEST"

echo "==> 提交更改"
git add "$LOCAL_MANIFEST"
git commit -m "sync: update runtime manifest from upstream

Synced from: $UPSTREAM_MANIFEST
At: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

echo "✓ 运行时清单已同步"
