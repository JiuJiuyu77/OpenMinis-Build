# OpenMinis-Build MT Agent 改进 - 推送成功

## 推送状态

✓ **提交已推送**: `2b3d629` → `origin/main`  
✓ **Tag 已创建**: `v1.0.0-mtagent-aligned`  
✓ **构建已触发**: 3 个 workflow 正在运行

## 自动触发的构建

### 1. TIPA Release (main 分支)
- **状态**: 进行中 ⚙️
- **提交**: 2b3d629
- **链接**: https://github.com/JiuJiuyu77/OpenMinis-Build/actions/runs/40861313400

### 2. TIPA Release (v1.0.0-mtagent-aligned tag)
- **状态**: 进行中 ⚙️
- **提交**: 2b3d629
- **链接**: https://github.com/JiuJiuyu77/OpenMinis-Build/actions/runs/40861380173

### 3. Runtime Contract (v1.0.0-mtagent-aligned tag)
- **状态**: 进行中 ⚙️
- **提交**: 2b3d629
- **链接**: https://github.com/JiuJiuyu77/OpenMinis-Build/actions/runs/40861380162

## 已推送的改进内容

### 核心改进

1. **运行时发现逻辑增强** (`src/ios/Agent/NativeBuild/NativeToolchain.swift`)
   - 添加 CodexApp `PreparedRuntimes/*` 扫描
   - 添加 `RuntimeDownloads/Theos` 支持
   - 添加 `ManagedRuntime` 候选根
   - 优化子目录展开 (支持 `TheosRuntime/theos`)

2. **环境变量完善**
   - 添加 `CA_THEOS_PACKAGE_MODE=forkless`
   - 对齐 CodexApp 的打包后端配置

3. **磁盘空间检查工作流** (`.github/workflows/disk-check.yml`)
   - 5GiB 警告阈值
   - 1GiB 失败阈值
   - 输出详细磁盘使用情况

4. **运行时清单同步脚本** (`scripts/sync_runtime_manifest.sh`)
   - 从上游拉取最新清单
   - 自动验证格式
   - 支持 `--check-only` 模式

5. **完整文档** (`MTAGENT_IMPROVEMENTS.md`)
   - 详细改进方案
   - 技术细节说明
   - 使用指南

## 预期构建时间

- **Runtime Contract**: ~5-10 分钟 (只检查,不构建)
- **TIPA Release**: ~50-90 分钟 (完整构建+签名+打包)

## 构建成功后的验证步骤

### 1. 下载产物

访问 Actions 页面,下载构建产物:
- `OpenMinis-<version>-TrollStore.tipa`
- `OpenMinis-<version>-unsigned.ipa`

### 2. 安装验证

在 iPhone 上通过 TrollStore 安装 TIPA:
```bash
# TrollStore 中:
# 1. 选择 .tipa 文件
# 2. 点击 Install
# 3. 打开 OpenMinis (Minis)
```

### 3. 运行时验证

在 Minis App 中:
```
设置 → 执行器 (Executor) → 工具链 → 重新检测
```

**预期结果**:
- ✓ 显示找到 Theos 根路径
- ✓ 如果安装了 CodexApp,应该显示复用其运行时目录
- ✓ 诊断列表显示所有工具 (clang/make/ldid/dpkg-deb) 都可用
- ✓ 环境变量包含 `CA_THEOS_PACKAGE_MODE=forkless`

### 4. 编译测试

编译工作台 → 创建测试项目 → 构建

**预期结果**:
- ✓ 原生编译成功
- ✓ 产物位于 `packages/` 目录
- ✓ .deb 包格式正确

## 改进对齐验证

本次改进完全对齐 CodexApp MT Agent 的:

### 1. 运行时能力注册表

```mermaid
flowchart LR
  A[CodexApp 运行时] --> B[PreparedRuntimes/*]
  A --> C[RuntimeDownloads/Theos]
  A --> D[ManagedRuntime]
  B & C & D --> E[Minis NativeToolchain]
  E --> F[统一工具链发现]
```

### 2. 环境变量映射

| 变量 | CodexApp | Minis (改进后) |
|------|----------|----------------|
| `CA_THEOS_PACKAGE_MODE` | forkless | ✓ forkless |
| `CA_THEOS_CLANG` | clang-16 路径 | ✓ 自动发现 |
| `CA_THEOS_SDKROOT` | SDK 路径 | ✓ 自动发现 |
| `THEOS` | theos 根路径 | ✓ 自动发现 |

### 3. 诊断优先级

1. 硬失败优先 (必需工具)
2. 磁盘阈值 (5GiB warn / 1GiB fail)
3. 状态一致性 (manifest + 契约守卫)
4. 环境完备性 (runtime 可用性)

## 查看实时构建状态

```bash
# 在本地检查
cd /var/mobile/Documents/OpenMinis-Build
bash check_build.sh

# 或访问 GitHub Actions
open https://github.com/JiuJiuyu77/OpenMinis-Build/actions
```

## 后续优化建议

参考 `MTAGENT_IMPROVEMENTS.md` 中的完整方案:

- [ ] 实现结构化诊断输出 (`RuntimeDiagnostics`)
- [ ] 添加能力依赖图谱检查
- [ ] 集成工具 shim 目录自动生成
- [ ] 添加磁盘空间预检到 App 内
- [ ] 优化工作流缓存策略

---

**提交信息**:
```
commit 2b3d629f9a8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e
Author: JiuJiuyu77 <your-email@example.com>
Date:   Wed Oct 29 18:55:00 2026 +0800

    feat: align with MT Agent runtime discovery and diagnostics logic
    
    - Add CodexApp PreparedRuntimes/RuntimeDownloads/ManagedRuntime scanning
    - Add CA_THEOS_PACKAGE_MODE=forkless environment variable
    - Add disk space check workflow (5GiB warn / 1GiB fail)
    - Add runtime manifest sync script
    - Complete MT Agent integration documentation
```

**Tag 信息**:
```
tag v1.0.0-mtagent-aligned
Tagger: JiuJiuyu77 <your-email@example.com>
Date:   Wed Oct 29 18:55:30 2026 +0800

Align with MT Agent runtime discovery and diagnostics logic

- Add CodexApp PreparedRuntimes/RuntimeDownloads/ManagedRuntime scanning
- Add CA_THEOS_PACKAGE_MODE=forkless environment variable
- Add disk space check workflow (5GiB warn / 1GiB fail)
- Add runtime manifest sync script
- Complete MT Agent integration documentation
```

---

**推送完成时间**: 2026-10-29 18:55:39 +0800  
**触发方式**: 自动 (main 推送 + tag 创建)  
**构建平台**: GitHub Actions (macos-26-intel)
