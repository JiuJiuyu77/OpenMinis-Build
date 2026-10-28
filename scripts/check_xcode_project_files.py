#!/usr/bin/env python3
"""Fail when a Swift file exists on disk but is not registered in the Xcode project.

`Agent/NativeBuild` is a PBXFileSystemSynchronizedRootGroup (files are picked up
automatically), but `Agent/Runtime` and the Views are classic groups: a new file
must appear in project.pbxproj four times (PBXBuildFile, PBXFileReference, group
children, Sources build phase). Forgetting that compiles fine locally in an
editor but breaks the app build with "cannot find type X in scope" — which is
exactly how a release build failed once.

Usage:
    scripts/check_xcode_project_files.py            # report only
    scripts/check_xcode_project_files.py --strict   # exit 1 when a file is missing
"""
import argparse
import os
import re
import sys

PROJECT = "src/ios/Minis.xcodeproj/project.pbxproj"
SOURCE_ROOT = "src/ios"

# Directories that are PBXFileSystemSynchronizedRootGroup (Xcode picks files up
# automatically, no pbxproj entry needed). Read from the project at run time so
# this list cannot drift.
SYNCHRONIZED_FALLBACK = ("Agent/NativeBuild",)
IGNORED_PREFIXES = (
    "MinisTests/", "MinisUITests/", "MinisTestHost/", "Preview Content/",
    "Vendor/", "Debug/", "default_mount/", "Resources/", "AgentWidget/",
    "ShareExtension/", "FileProvider/", "Diagnostics/", "Providers/", "iSH/",
)
# 样例文件，刻意不参与 App target 编译。
IGNORED_NAMES = {"Package.swift", "ISHCommandExecutionExample.swift"}


def synchronized_groups(project_text):
    """Folder names declared as synchronized root groups in the project."""
    names = set(SYNCHRONIZED_FALLBACK)
    for line in project_text.splitlines():
        if "PBXFileSystemSynchronizedRootGroup" not in line:
            continue
        match = re.search(r'path = ([^;]+);', line)
        if match:
            names.add(match.group(1).strip().strip('"'))
    # 目录名可能重复（例如 ContentView 出现在两层），按名字整段匹配即可。
    return names


def is_synchronized(relative_dir, names):
    return any(part in names for part in relative_dir.split("/"))


def swift_files(names):
    found = []
    for directory, dirnames, filenames in os.walk(SOURCE_ROOT):
        relative_dir = os.path.relpath(directory, SOURCE_ROOT).replace("\\", "/")
        if relative_dir == ".":
            relative_dir = ""
        if any(relative_dir.startswith(p.rstrip("/")) for p in IGNORED_PREFIXES):
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in (".git", "build", "DerivedData")]
        if is_synchronized(relative_dir, names):
            continue
        for name in filenames:
            if name.endswith(".swift") and name not in IGNORED_NAMES:
                found.append((name, os.path.join(relative_dir, name) if relative_dir else name))
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", default=PROJECT)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(argv)

    text = open(args.project, encoding="utf-8", errors="replace").read()
    registered = set(re.findall(r"path = ([^;\"]+\.swift);", text)) | set(
        re.findall(r"/\* ([^*]+\.swift) in Sources \*/", text))

    files = swift_files(synchronized_groups(text))
    missing = [(name, path) for name, path in files if name not in registered]
    print("%d Swift files outside synchronized groups · %d registered names in project"
          % (len(files), len(registered)))
    if missing:
        print("\nnot registered in project.pbxproj (%d):" % len(missing))
        for name, path in sorted(missing):
            print("  %-42s %s" % (name, path))
        return 1 if args.strict else 0
    print("every file is referenced by the project")
    return 0


if __name__ == "__main__":
    sys.exit(main())
