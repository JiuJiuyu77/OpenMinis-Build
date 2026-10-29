# Codex CLI 移除与重命名计划

## 背景

OpenMinis (Minis) 中存在两种 "Codex" 混淆:
1. **Codex OAuth** - OpenAI 的 ChatGPT 订阅认证方式 (保留)
2. **Codex CLI/Runtime** - OpenAI 的命令行工具运行时包 (移除,Minis 有其他方案)
3. **codex-sign** - MT 的签名工具 (重命名为 minis-sign)

## 改进目标

1. 移除对 Codex CLI 运行时包的依赖
2. 重命名 codex-sign → minis-sign
3. 保留 Codex OAuth 相关代码 (LLMModel.allOpenAICodexOAuth 等)
4. 更新所有文档和注释

## 需要修改的文件

### 1. 签名工具重命名

**文件**: `src/ios/Agent/Runtime/RuntimeSigning.swift`
- 函数 `locateCodexSign()` → `locateMinisSign()`
- 变量 `codexSign` → `minisSign`
- 字符串 `"codex-sign"` → `"minis-sign"`
- 注释中的 `codex-sign` → `minis-sign`

**文件**: `src/ios/Agent/NativeBuild/IPAShellPacker.swift`
**文件**: `src/ios/Agent/NativeBuild/ToolExecutorPreference.swift`
**文件**: `src/ios/Agent/NativeBuild/NativeBuildService.swift`
**文件**: `src/ios/Views/Settings/RuntimeDiagnosticsView.swift`

### 2. 移除 Codex 运行时依赖

**文件**: `src/ios/Agent/Runtime/DeveloperRuntimeManager.swift`
- 保持 `unsupportedHandlers = ["codex"]` (因为不再支持安装 Codex CLI)
- 更新注释说明原因

**文件**: `src/ios/Agent/Runtime/DebArchive.swift`
- 更新注释: 不再提及 codex 作为使用案例
- 说明这是通用的 .deb 解包器

**文件**: `src/ios/Agent/Runtime/RuntimeInstallSpec.swift`
- 移除 codex 相关示例
- 更新注释

**文件**: `src/ios/Agent/Runtime/RuntimeManifest.swift`
- 移除 codex handler 相关逻辑
- 保留通用的 handler 框架

### 3. 更新文档

**文件**: `docs/DeveloperRuntime.md`
- 移除 codex 运行时的描述
- 说明 Minis 使用自己的签名方案 (minis-sign)

**文件**: `MTAGENT_IMPROVEMENTS.md`
- 更新所有 codex-sign 引用

### 4. 保留的 Codex 引用

**不修改** 以下文件中的 Codex OAuth 引用:
- `src/ios/Providers/LLMTypes.swift` - `allOpenAICodexOAuth`
- `src/ios/Providers/OpenAIProvider.swift` - `codexClientVersion`
- `src/ios/MinisTests/GPT6*.swift` - 测试文件中的 Codex OAuth

这些是 OpenAI 的认证机制,与 Codex CLI 无关。

## 实现步骤

1. 在 App Bundle 中重命名二进制: `Helpers/codex-sign` → `Helpers/minis-sign`
2. 全局查找替换 `codex-sign` → `minis-sign` (排除 OAuth 相关)
3. 更新 RuntimeSigning.swift 中的函数名和变量名
4. 清理 Runtime 模块中对 codex CLI 的注释
5. 更新文档
6. 运行测试验证

## 验证清单

- [ ] `minis-sign` 二进制存在于 `Helpers/`
- [ ] 所有 Swift 代码中 `codex-sign` 已替换
- [ ] Runtime 签名功能正常工作
- [ ] Codex OAuth (LLM 模型) 功能未受影响
- [ ] 文档已更新
- [ ] 测试通过
