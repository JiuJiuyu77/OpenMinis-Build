# Node.js 24 升级方案

## 背景

MT Agent 1.1.0 已在上游运行时仓库发布 Node.js 24.5.0 预编译包：
- 仓库: https://github.com/susu123oss/CodexApp-Runtime/releases
- 版本: Node.js 24.5.0 + npm 11.5.1
- 架构: iOS arm64 (TrollStore 和越狱通用)

## 当前 OpenMinis-Build 状态

OpenMinis-Build 已具备运行时集成能力，但需要：
1. 添加 Node.js 24 运行时清单配置
2. 更新 `NativeToolchain` 以支持新版本 Node.js
3. 文档更新说明 Node.js 24 支持

## 实施步骤

### 1. 创建运行时清单

创建 `Runtime/node24-manifest.json`:

```json
{
  "format_version": 1,
  "node": {
    "version": "24.5.0",
    "npm_version": "11.5.1",
    "architecture": "arm64",
    "platform": "ios",
    "source": "https://github.com/susu123oss/CodexApp-Runtime/releases",
    "features": [
      "native_addons",
      "n-api",
      "child_process",
      "worker_threads",
      "fetch"
    ]
  }
}
```

### 2. 更新 NativeToolchain

在 `src/ios/Agent/NativeBuild/NativeToolchain.swift` 中添加 Node.js 24 检测逻辑。

### 3. 文档更新

- `README.md`: 添加 Node.js 24 支持说明
- `BUILDING.md`: 更新构建文档

## 兼容性

- 向后兼容 Node.js 18.20.4
- 优先检测 Node.js 24，回退到 18
- 保持与 MT Agent 1.1.0 一致

## 验证

构建成功后在 Minis App 中：
1. 设置 → 执行器 → Node.js 版本应显示 24.5.0
2. 原生模块编译测试通过
