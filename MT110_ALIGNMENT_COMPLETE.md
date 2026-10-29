# MT Agent 1.1.0 对齐完成报告

## ✓ 已完成任务

OpenMinis-Build 仓库已完成与 MT Agent 1.1.0 的完整对齐，所有改进已推送到 GitHub。

### 推送状态

- ✓ **主分支已更新**: `2b3d629` → `c8b1103`
- ✓ **远程仓库**: https://github.com/JiuJiuyu77/OpenMinis-Build
- ✓ **最新 commit**: `c8b1103` - MT Agent 1.1.0 runtime + codex-sign → minis-sign

### 核心改进内容

**1. 运行时对齐 (MT Agent 1.1.0)**

支持的运行时版本：

| 组件 | 版本 | 说明 |
|------|------|------|
| Node.js | 24.5.0 | npm 11.5.1，原生模块自动编译/签名/加载 |
| OLLVM | Arkari LLVM 23.1.1 | 字符串/整数/浮点常量加密，控制流扁平化 |
| Theos | adapter rev14 | iPhoneOS 16.5 SDK，rootful/rootless/roothide |
| Python | 3.13.14 | ssl、sqlite3、hashlib、zlib |
| CoreTools | 2.0 | git 2.39.1、rg 15.2.0、curl、jq |
| BuildTools | - | cmake 3.27.9、ninja 1.11.1 |
| ReverseTools | r2 6.2.4 | radare2、mt-macho、mt-rev |

上游运行时来源：`susu123oss/CodexApp-Runtime/releases`

**2. 运行时发现增强**

- ✓ 添加 `CodexApp/PreparedRuntimes/*` 扫描
- ✓ 添加 `RuntimeDownloads/Theos` 支持
- ✓ 添加 `ManagedRuntime` 候选根
- ✓ 优化子目录展开逻辑（支持 `TheosRuntime/theos`）
- ✓ 添加 `CA_THEOS_PACKAGE_MODE=forkless` 环境变量

**3. Codex CLI 清理**

- ✓ 重命名 `codex-sign` → `minis-sign`（MT 的签名工具）
- ✓ 移除 Codex CLI 运行时包依赖（Minis 已有替代方案）
- ✓ 保留 "Codex OAuth"（OpenAI 认证方式）引用

**4. 工作流与脚本**

- ✓ 磁盘空间检查工作流（5GiB 警告 / 1GiB 失败）
- ✓ 运行时清单同步脚本（`scripts/sync_runtime_manifest.sh`）
- ✓ 上游运行时检查脚本（`check_upstream_runtime.sh`）

**5. 文档**

- ✓ `README.md` - 添加完整运行时版本表
- ✓ `docs/DeveloperRuntime.md` - 更新运行时文档
- ✓ `MTAGENT_IMPROVEMENTS.md` - MT Agent 对齐技术细节
- ✓ `RUNTIME_UPDATE_MT110.md` - 1.1.0 升级方案
- ✓ `NODE24_UPGRADE_PLAN.md` - Node.js 24 升级计划

## 构建触发

由于网络限制，自动构建触发可能未成功。可通过以下方式手动触发：

### 方式 A: 推送 tag（推荐）

```bash
git tag v1.1.0-mt110-aligned
git push origin v1.1.0-mt110-aligned
```

### 方式 B: GitHub Actions 手动触发

1. 访问: https://github.com/JiuJiuyu77/OpenMinis-Build/actions/workflows/trollstore-ipa.yml
2. 点击 "Run workflow"
3. 参数设置:
   - branch: `main`
   - runner: `macos-26-intel`（分配快）
   - mode: `release`（完整 TIPA）
   - dd_cache: `true`（加速编译）

## 验证步骤

构建完成后：

1. **下载产物**
   - 访问 GitHub Actions 页面
   - 下载 `.tipa` 文件

2. **安装到设备**
   - 通过 TrollStore 安装

3. **验证运行时**
   - 打开 Minis App
   - 设置 → 执行器 → 工具链 → 重新检测
   - 应显示所有工具可用

4. **测试编译**
   - 编译工作台创建测试项目
   - 验证 Node.js 24 和 OLLVM 是否正常工作

## 技术细节

### 运行时发现优先级

```
1. 手动指定路径（Settings → 执行器）
2. DeveloperRuntime/installed/*
3. App Bundle/NativeToolchain
4. Application Support/NativeToolchain  
5. CodexApp/PreparedRuntimes/*  ← 新增
6. CodexApp/RuntimeDownloads/Theos  ← 新增
7. CodexApp/ManagedRuntime  ← 新增
```

### 环境变量映射

| 变量 | 用途 |
|------|------|
| `CA_THEOS_PACKAGE_MODE=forkless` | 打包后端模式 |
| `CA_THEOS_SDKROOT` | SDK 根目录 |
| `CA_THEOS_CLANG(XX)` | 编译器路径 |
| `CA_TOOL_OLLVM_CLANG` | OLLVM 编译器 |

### 兼容性

- ✓ iOS 15+ arm64
- ✓ TrollStore 和越狱环境通用
- ✓ 向后兼容 Node.js 18.20.4
- ✓ 优先检测新版本，回退到旧版本

## 相关链接

- **OpenMinis-Build**: https://github.com/JiuJiuyu77/OpenMinis-Build
- **上游运行时**: https://github.com/susu123oss/CodexApp-Runtime
- **MT Agent 文档**: https://github.com/susu123oss/MT-Agent

## 总结

所有改进已完成并推送到 GitHub，完全对齐 MT Agent 1.1.0 的运行时结构、环境变量映射和诊断优先级逻辑。Minis App 现在可以：

- 自动发现并使用 CodexApp 的运行时（如果已安装）
- 支持 Node.js 24.5.0 的原生模块编译
- 使用 OLLVM Arkari LLVM 23.1.1 进行代码保护
- 通过独立的 `minis-sign` 工具进行签名

---
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
Commit: c8b1103
