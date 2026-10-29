# 运行时更新：对齐 MT Agent 1.1.0

## 概述

基于上游 MT Agent 1.1.0，更新以下运行时组件：

1. **Node.js 24.5.0 + npm 11.5.1** - 新版本 Node.js 运行时
2. **OLLVM (Arkari LLVM 23.1.1)** - 代码混淆保护编译器更新

## 更新内容

### 1. Node.js 24.5.0

**特性：**
- 最新 V8 引擎，性能提升
- 原生模块编译支持 (node-gyp + N-API)
- iOS arm64 优化编译
- 支持 fetch、worker_threads、child_process

**来源：** `https://github.com/susu123oss/CodexApp-Runtime/releases`

**集成方式：**
- 在 `NativeToolchain` 中添加 Node.js 24 路径检测
- 优先级：Node 24 > Node 18 (向后兼容)
- 环境变量：`CA_TOOL_NODE_RUNTIME_ROOT`

### 2. OLLVM 更新

**当前版本：** Arkari LLVM 23.1.1  
**支持的混淆 pass：**
- `--irobf-cse` - 字符串加密
- `--irobf-cie` - 整型常量加密
- `--irobf-cfe` - 浮点常量加密
- `--irobf-fla` - 控制流扁平化

**集成状态：**
- ✓ 已在 `NativeToolchain` 中实现检测
- ✓ 支持 arm64 和 arm64e 架构
- ✓ 与 Theos 工具链集成

## 实施步骤

### 阶段 1: 文档更新

更新 `README.md` 说明 Node.js 24 和 OLLVM 支持：

```markdown
## 运行时支持

### Node.js
- ✓ Node.js 24.5.0 (推荐) - 包含 npm 11.5.1 和原生模块编译
- ✓ Node.js 18.20.4 (兼容) - 向后兼容旧版本

### OLLVM 代码保护
- Arkari LLVM 23.1.1
- 支持字符串加密、常量加密、控制流扁平化
- arm64 / arm64e 双架构支持
```

### 阶段 2: 代码更新

在 `src/ios/Agent/NativeBuild/NativeToolchain.swift` 中：

1. 添加 Node.js 版本检测逻辑
2. 优先检测 Node 24，回退到 Node 18
3. 确保 OLLVM 检测逻辑完整

### 阶段 3: 测试验证

构建完成后验证：
1. Minis App → 设置 → 执行器 → Node.js 版本
2. 原生模块编译测试
3. OLLVM 混淆编译测试

## 兼容性矩阵

| 组件 | 版本 | iOS 最低要求 | 架构 | TrollStore | 越狱 |
|------|------|-------------|------|-----------|------|
| Node.js 24 | 24.5.0 | iOS 15.0 | arm64 | ✓ | ✓ |
| Node.js 18 | 18.20.4 | iOS 15.0 | arm64 | ✓ | ✓ |
| OLLVM | 23.1.1 | iOS 15.0 | arm64/arm64e | ✓ | ✓ |

## 发布说明

更新后的 OpenMinis-Build 将完全对齐 MT Agent 1.1.0 的运行时能力。

