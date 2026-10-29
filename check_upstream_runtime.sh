#!/bin/bash
# 检查上游运行时资源变更
set -e

echo "检查上游 OpenMinis 的运行时变更..."

# 获取当前状态
CURRENT_COMMIT=$(git rev-parse HEAD)
UPSTREAM_COMMIT=$(git rev-parse upstream/main 2>/dev/null || echo "未拉取")

echo "当前提交: $CURRENT_COMMIT"
echo "上游提交: $UPSTREAM_COMMIT"

# 如果上游未拉取,先拉取
if [ "$UPSTREAM_COMMIT" = "未拉取" ]; then
    echo "拉取上游分支..."
    # 使用之前的 token
    git remote set-url upstream https://github.com/OpenMinis/OpenMinis.git
fi

echo ""
echo "检查运行时相关文件差异..."

# 检查关键文件
FILES_TO_CHECK=(
    "src/ios/Agent/Runtime/"
    "docs/DeveloperRuntime.md"
    "scripts/sync_runtime_manifest.sh"
)

for file in "${FILES_TO_CHECK[@]}"; do
    if [ -e "$file" ]; then
        echo "✓ $file 存在"
    else
        echo "✗ $file 不存在"
    fi
done

echo ""
echo "检查 Codex 相关命名..."
rg -i "codex" src/ios/Agent/Runtime/ --type swift -c 2>/dev/null || echo "运行时模块无 codex 引用"

echo ""
echo "检查 AI 层实现..."
ls -1 src/ios/Agent/Chat/AIChatViewModel*.swift | wc -l | xargs echo "AI 层文件数:"
