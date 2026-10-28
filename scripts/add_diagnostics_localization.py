#!/usr/bin/env python3
"""Add the strings introduced by the diagnostics rework to Localizable.xcstrings.

The catalogue is a generated .xcstrings; adding hundreds of keys by hand through
JSON is what produced broken states before, so this script takes an explicit
table, skips keys that already exist, and writes the file back atomically with
the same formatting Xcode uses (sorted keys, 2-space indent).

Usage: scripts/add_diagnostics_localization.py [--dry-run]
"""
import argparse
import json
import os
import sys

CATALOG = "src/ios/Localizable.xcstrings"

# key: (zh-Hans, zh-Hant)
STRINGS = {
    "Show details": ("查看详情", "查看詳情"),
    "Hide details": ("收起详情", "收起詳情"),
    "Repair this item": ("修复此项", "修復此項"),
    "Repairing…": ("修复中…", "修復中…"),
    "No shell could be started on this device": ("这台设备上无法启动 shell 子进程", "這台裝置上無法啟動 shell 子程序"),
    "No shell could be started on this device — the filesystem probe never ran.":
        ("无法启动子进程，文件系统检查没有真正跑", "無法啟動子程序，檔案系統檢查沒有真正執行"),
    "never self-checked": ("从未自检", "從未自檢"),
    "self-check passed": ("自检通过", "自檢通過"),
    "self-check skipped": ("自检跳过", "自檢略過"),
    "self-check failed": ("自检失败", "自檢失敗"),
    "never signed": ("从未签名", "從未簽名"),
    "signed": ("已签名", "已簽名"),
    "ad-hoc only": ("仅 adhoc", "僅 adhoc"),
    "signing skipped": ("签名跳过", "簽名略過"),
    "signing failed": ("签名失败", "簽名失敗"),
    "Native execution works now": ("原生执行已恢复", "原生執行已恢復"),
    "Could not start a child process": ("仍然无法启动子进程", "仍然無法啟動子程序"),
    "Nothing to sign": ("没有可签名的运行时", "沒有可簽名的執行環境"),
    "No runtime is installed, so there is nothing to re-sign.":
        ("还没安装运行时，没有可重签的对象", "還沒安裝執行環境，沒有可重簽的對象"),
    "failed": ("失败", "失敗"),
    "Runtime binaries re-signed": ("运行时已重新签名", "執行環境已重新簽名"),
    "Signing partially failed": ("部分文件签名失败", "部分檔案簽名失敗"),
    "Some binaries could not be signed. If ldid is missing, reinstall the Theos runtime (it ships its own ldid).":
        ("有些文件签不了。ldid 缺失的话请重装 Theos 运行时（它自带 ldid）。",
         "有些檔案簽不了。ldid 缺少的話請重裝 Theos 執行環境（它自帶 ldid）。"),
    "Nothing to verify": ("没有可自检的运行时", "沒有可自檢的執行環境"),
    "No runtime is installed yet.": ("还没安装运行时", "還沒安裝執行環境"),
    "missing": ("缺失", "缺少"),
    "Every runtime passed its self-check": ("所有运行时都通过自检", "所有執行環境都通過自檢"),
    "Some runtimes failed their self-check": ("有运行时自检失败", "有執行環境自檢失敗"),
    "Nothing to repair": ("无需修复", "無需修復"),
    "Native execution already works — nothing to reinstall.":
        ("原生执行本来就正常，不用重装", "原生執行本來就正常，不用重裝"),
    "The runtime files are intact; the failure is elsewhere: ":
        ("运行时文件是完整的，问题在别处：", "執行環境檔案是完整的，問題在別處："),
    "Runtime is not the problem": ("问题不在运行时文件", "問題不在執行環境檔案"),
    "Cannot reinstall automatically": ("无法自动重装", "無法自動重裝"),
    "Reinstalling ": ("正在重装 ", "正在重裝 "),
    "Reinstall did not fix it": ("重装后仍然不行", "重裝後仍然不行"),
    "Runtime reinstalled": ("运行时已重装", "執行環境已重裝"),
    "The toolchain runs now": ("工具链已可用", "工具鏈已可用"),
    "Still failing: ": ("仍然失败：", "仍然失敗："),
    "No usable shell on this device": ("这台设备上没有可用的 shell", "這台裝置上沒有可用的 shell"),
    "not executable": ("没有可执行权限", "沒有可執行權限"),
    "not usable": ("不可用", "不可用"),
    "This device is jailbroken/TrollStore-capable, but this build is signed without no-sandbox / platform-application — native execution stays blocked.":
        ("设备是越狱/巨魔环境，但这个包没有 no-sandbox / platform-application 权限 —— 原生执行仍然会被拦",
         "裝置是越獄/巨魔環境，但這個包沒有 no-sandbox / platform-application 權限 —— 原生執行仍然會被攔"),
    "This device cannot run native binaries, so ldid cannot sign anything here.":
        ("这台设备跑不了原生二进制，ldid 在这里签不了名",
         "這台裝置跑不了原生二進位，ldid 在這裡簽不了名"),
}


def entry(key, hans, hant):
    return {
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": key}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": hans}},
            "zh-Hant": {"stringUnit": {"state": "translated", "value": hant}},
        }
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog", default=CATALOG)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    with open(args.catalog, encoding="utf-8") as handle:
        catalog = json.load(handle)

    strings = catalog["strings"]
    added, skipped = [], []
    for key, (hans, hant) in STRINGS.items():
        if key in strings:
            skipped.append(key)
            continue
        strings[key] = entry(key, hans, hant)
        added.append(key)

    print("added %d · already present %d · catalogue size %d" % (len(added), len(skipped), len(strings)))
    for key in added:
        print("  + " + key)

    if args.dry_run or not added:
        return 0

    # 不要重排：Xcode 写出的顺序不是字典序，重排会让整份文件变成噪音 diff。
    temp = args.catalog + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temp, args.catalog)
    return 0


if __name__ == "__main__":
    sys.exit(main())
