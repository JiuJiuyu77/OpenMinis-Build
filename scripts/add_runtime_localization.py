#!/usr/bin/env python3
"""Insert zh-Hans entries into Localizable.xcstrings without reformatting it.

The repo's add_localization.py cannot parse this catalog's current formatting
("could not locate any entry boundaries"), and re-serialising 288k lines would
bury the real change in diff noise. This script does a textual insert in the
same style as the neighbouring entries.
"""
import json
import re
import subprocess
import sys

CATALOG = "src/ios/Localizable.xcstrings"

TRANSLATIONS = {
    # install self-check
    "Ad-hoc signed only": "仅完成 adhoc 签名",
    "Archive is incomplete: missing required paths.": "归档不完整：缺少必需路径。",
    "Cannot execute native binaries in this environment.": "当前环境无法执行原生二进制。",
    "Cannot run the signing tools in this environment.": "当前环境无法运行签名工具。",
    "Missing:": "缺少：",
    "No probe declared.": "未声明自检命令。",
    "Probe executable is missing or not executable.": "自检程序不存在或不可执行。",
    "Probe exited with a non-zero status.": "自检命令返回非零状态。",
    "Probe output did not contain the expected marker.": "自检输出未包含预期标记。",
    "Probe timed out.": "自检超时。",
    "Runtime self-check failed.": "运行时自检失败。",
    "Self-check failed": "自检失败",
    "Self-check passed": "自检通过",
    "Self-check skipped": "未做自检",
    "This runtime does not publish a self-check.": "该运行时未提供自检。",
    # signing
    "Signed (ldid + codex-sign)": "已签名（ldid + codex-sign）",
    "Signing failed": "签名失败",
    "Signing failed.": "签名失败。",
    "Signing skipped": "未签名",
    "signing unavailable": "签名不可用",
    "This app is not signed with native entitlements, so runtime binaries cannot be made executable.":
        "本 App 未以原生权限签名，运行时二进制无法获得执行权限。",
    "This runtime declares no binaries to sign.": "该运行时没有声明需要签名的二进制。",
    "codex-sign is not bundled, so the App Store-style CodeDirectory is missing.":
        "未内置 codex-sign，缺少 App Store 形态的 CodeDirectory。",
    "ldid was not found. Install the Theos runtime first.": "找不到 ldid，请先安装 Theos 运行时。",
    "No Mach-O output to sign.": "没有需要签名的 Mach-O 产物。",
    # codex handling
    "This runtime belongs to another app's agent stack and is not installed by Minis.":
        "该运行时属于其它 App 的 Agent 架构，本 App 不安装。",
    # runtime capabilities
    "Node.js runtime": "Node.js 运行时",
    "Python runtime": "Python 运行时",
    "Core tools (git/rg/curl/jq)": "基础工具（git/rg/curl/jq）",
    "CMake + Ninja": "CMake + Ninja",
    "Reverse tools (radare2)": "逆向工具（radare2）",
    "Node with npm/corepack from the Developer Runtime manifest.":
        "运行时清单提供的 Node 与 npm/corepack。",
    "Managed CPython from the Developer Runtime manifest.": "运行时清单提供的 CPython。",
    "Git, ripgrep, curl and jq from the CoreTools runtime.":
        "来自 CoreTools 运行时的 git、ripgrep、curl 与 jq。",
    "CMake and Ninja from the BuildTools runtime.": "来自 BuildTools 运行时的 CMake 与 Ninja。",
    "radare2 and Mach-O tooling from the ReverseTools runtime.":
        "来自 ReverseTools 运行时的 radare2 与 Mach-O 工具。",
    "Install it from Settings → Developer Runtime.": "请到 设置 → Developer Runtime 安装。",
    # diagnostics: three layers
    "Native execution (3 layers)": "原生执行（三层）",
    "Child process identity": "子进程身份",
    "uid / gid a posix_spawn child inherits": "posix_spawn 子进程继承的 uid / gid",
    "Filesystem boundary": "文件系统边界",
    "Writable: /tmp, Library, Media · read-only: /, /System/Library":
        "可写：/tmp、Library、Media · 只读：/、/System/Library",
    "TCC boundary": "TCC 边界",
    "SMS / CallHistory / TCC stay unreadable despite root":
        "即使是 root 也读不到短信 / 通话 / TCC",
    "Signing layer": "签名层",
    "ldid + codex-sign, and the entitlements they propagate":
        "ldid + codex-sign，以及它们传播的 entitlements",
    "Runtime self-checks": "运行时自检",
    "Per-runtime self-check and signing outcome": "每个运行时的自检与签名结论",
    "No native shell available": "没有可用的原生 shell",
    "Child processes are not root": "子进程不是 root",
    "Could not read the child process identity": "读不到子进程身份",
    "Expected writable directories are not writable": "预期可写的目录写不进去",
    "SSV read-only volumes became writable (unexpected)": "SSV 只读卷变成可写（异常）",
    "%ld writable · %ld read-only (SSV intact)": "%ld 个可写 · %ld 个只读（SSV 完好）",
    "%ld protected stores denied": "%ld 个受保护数据被拒绝读取",
    "A TCC-protected store is readable": "有受 TCC 保护的数据可读",
    "ldid + codex-sign · %ld entitlements to propagate":
        "ldid + codex-sign · 可传播 %ld 条 entitlements",
    "codex-sign is not bundled": "未内置 codex-sign",
    "%ld entitlements · ad-hoc signing only": "%ld 条 entitlements · 仅 adhoc 签名",
    "ldid was not found": "找不到 ldid",
    "Install the Theos runtime to enable signing.": "安装 Theos 运行时即可启用签名。",
    "A runtime failed its self-check or signing": "有运行时未通过自检或签名",
    "installed before self-checks existed": "早于自检机制安装",
    "No runtime installed": "未安装运行时",
    # executor cleanup
    "Toolchain source: this app's Developer Runtime only (no other app's runtime folders are scanned).":
        "工具链来源：仅本 App 的 Developer Runtime（不再扫描其它 App 的运行时目录）。",
}

KEY_RE = re.compile(r'^    "((?:[^"\\]|\\.)*)": \{$')


def existing_keys(lines):
    """All top-level keys, read in one pass without materialising JSON."""
    keys = set()
    for line in lines:
        match = KEY_RE.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def block(key, value):
    return [
        '    %s: {' % json.dumps(key, ensure_ascii=False),
        '      "localizations": {',
        '        "zh-Hans": {',
        '          "stringUnit": {',
        '            "state": "translated",',
        '            "value": %s' % json.dumps(value, ensure_ascii=False),
        '          }',
        '        }',
        '      }',
        '    },',
    ]


def main():
    dry_run = "--dry-run" in sys.argv
    with open(CATALOG, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    existing = existing_keys(lines)
    todo = {k: v for k, v in TRANSLATIONS.items() if k not in existing}
    print("catalog keys: %d · to insert: %d" % (len(existing), len(todo)))
    if not todo:
        return 0
    if dry_run:
        for key in sorted(todo):
            print("  + %s -> %s" % (key, todo[key]))
        return 0

    # 单次扫描插入：catalog 是 ASCII 升序，遇到第一个比待插入键更大的条目就吐出
    # 所有比它小的待插入条块。避免「每个键都重新解析 28 万行」的内存峰值
    # （iSH 沙箱里会直接 MemoryError）。
    pending = sorted(todo, key=lambda s: s.encode("utf-8"))
    raw_pending = sorted(todo.keys(), key=lambda s: s.encode("utf-8"))
    out = []
    emitted = 0
    for line in lines:
        match = KEY_RE.match(line)
        if match and emitted < len(raw_pending):
            raw = match.group(1)
            while emitted < len(raw_pending) and "    %s: {" % json.dumps(
                    raw_pending[emitted], ensure_ascii=False) < line:
                out.extend(block(raw_pending[emitted], todo[raw_pending[emitted]]))
                emitted += 1
        out.append(line)
    while emitted < len(raw_pending):
        # 追加到 strings 块末尾（最后一个 "  }" 之前）
        insert_at = len(out) - 1
        for index in range(len(out) - 1, -1, -1):
            if out[index] == "  }":
                insert_at = index
                break
        out[insert_at:insert_at] = block(raw_pending[emitted], todo[raw_pending[emitted]])
        emitted += 1

    with open(CATALOG, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))

    text = open(CATALOG, encoding="utf-8").read()
    missing = [k for k in TRANSLATIONS if json.dumps(k, ensure_ascii=False) + ": {" not in text]
    print("inserted %d · still missing %d" % (emitted, len(missing)))
    if missing:
        print("missing:", missing[:5])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
