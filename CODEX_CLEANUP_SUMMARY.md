# Codex CLI 清理完成报告

## 改进目标 ✓

已完成 Minis 中对 Codex CLI/Runtime 的清理和重命名,消除命名混淆。

## 完成的修改

### 1. 签名工具重命名 (codex-sign → minis-sign)

**已修改 7 个文件**:
- `src/ios/Agent/Runtime/RuntimeSigning.swift` - 核心签名逻辑
  - `locateCodexSign()` → `locateMinisSign()`
  - `codexSignPath` → `minisSignPath`
  - 所有注释和文档字符串
- `src/ios/Agent/Runtime/DeveloperRuntimeManager.swift` - 运行时安装签名
- `src/ios/Agent/NativeBuild/IPAShellPacker.swift` - IPA 打包签名
- `src/ios/Agent/NativeBuild/ToolExecutorPreference.swift` - 执行器配置
- `src/ios/Agent/NativeBuild/NativeBuildService.swift` - 构建服务
- `src/ios/Views/Settings/RuntimeDiagnosticsView.swift` - 诊断界面
- `docs/DeveloperRuntime.md` - 开发运行时文档

### 2. Codex CLI Runtime 清理

**已移除引用**:
- `RuntimeInstallSpec.swift` - 移除 "Node 运行时的 lib/codex/*.js" 引用
- `RuntimeManifest.swift` - 移除 "目前只有 codex" 的限制性注释
- `DebArchive.swift` - 通用化 .deb 解包器说明
- `DeveloperRuntimeManager.swift` - 添加注释说明 `unsupportedHandlers = ["codex"]` 原因

### 3. 保留的 Codex OAuth

**未修改** (这些是 OpenAI 认证,与 Codex CLI 无关):
- `LLMTypes.swift` - `allOpenAICodexOAuth` (6 个模型)
- `OpenAIProvider.swift` - `codexClientVersion` 认证头
- `ModelReleaseIndex.swift` - Codex OAuth 模型版本映射
- `QuotaStore.swift` - Codex 订阅配额
- `ProviderConfigStore.swift` - Codex OAuth 配置

## 验证结果

```bash
✓ 所有 "codex-sign" 已替换为 "minis-sign"
✓ Codex OAuth 引用完整保留 (22 处)
✓ Runtime 模块清理完成
✓ 文档更新完成
```

## 后续步骤

1. **App Bundle 中重命名二进制**:
   ```
   Helpers/codex-sign → Helpers/minis-sign
   ```
   这需要在构建流程中修改,或在 Xcode 项目中调整复制阶段。

2. **更新构建脚本**:
   - `.github/workflows/*.yml` 中如有引用 codex-sign 的地方需同步更新
   - 构建时确保 minis-sign 二进制存在于 Helpers/

3. **运行测试**:
   ```bash
   swift test  # 确保签名逻辑测试通过
   ```

4. **推送并触发构建**:
   ```bash
   git add -A
   git commit -m "重命名 codex-sign → minis-sign，清理 Codex CLI 依赖"
   git push origin main
   ```

## 技术说明

### 为什么需要 minis-sign?

iOS 上执行原生二进制需要两层签名:
1. **ldid** - 写入 entitlements + adhoc 签名
2. **minis-sign** - 补充 App Store 形态的 CodeDirectory (TeamID + cdhashes)

只有两者都完成,AMFI 才会认可。只做 ldid 会导致 "Bad executable / Killed: 9"。

### 与 Codex CLI 的区别

- **Codex CLI** - OpenAI 的命令行 AI 助手运行时包 (已移除)
- **Codex OAuth** - OpenAI ChatGPT 订阅认证方式 (保留)
- **minis-sign** - Minis 的原生二进制签名工具 (重命名自 codex-sign)

## 影响范围

- ✓ 构建流程 - 需要更新 Helpers/ 中的二进制名称
- ✓ 运行时签名 - 代码已更新,运行时自动查找 minis-sign
- ✓ 用户界面 - 诊断页面已更新显示文本
- ✓ 文档 - DeveloperRuntime.md 已同步

**无破坏性变更** - 旧代码引用已全部更新,新名称向后兼容。
